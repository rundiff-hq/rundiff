package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
)

type Assignment struct {
	ExecutionID   string `json:"execution_id"`
	AttemptNumber int    `json:"attempt_number"`
}

type Claim struct {
	Request              protocol.RequestV1 `json:"request"`
	LeaseExpiresAt       time.Time          `json:"-"`
	RepositoryCapability string             `json:"-"`
}

type claimWire struct {
	Request              protocol.RequestV1 `json:"request"`
	LeaseExpiresAt       string             `json:"lease_expires_at"`
	RepositoryCapability string             `json:"repository_capability,omitempty"`
}

type Heartbeat struct {
	Status             string  `json:"status"`
	LeaseExpiresAt     *string `json:"lease_expires_at,omitempty"`
	CancellationReason *string `json:"cancellation_reason,omitempty"`
}

type Submission struct {
	Status string `json:"status"`
}

type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

func (c *Client) Claim(ctx context.Context, assignment Assignment) (Claim, error) {
	var wire claimWire
	if err := c.postJSON(
		ctx,
		fmt.Sprintf(
			"/api/executions/%s/attempts/%d/claim",
			assignment.ExecutionID,
			assignment.AttemptNumber,
		),
		nil,
		&wire,
		http.StatusOK,
	); err != nil {
		return Claim{}, err
	}
	if err := wire.Request.Validate(); err != nil {
		return Claim{}, fmt.Errorf("invalid claimed request: %w", err)
	}
	if wire.Request.ExecutionID != assignment.ExecutionID ||
		wire.Request.AttemptNumber != assignment.AttemptNumber {
		return Claim{}, errors.New("claimed request identity mismatch")
	}
	expiresAt, err := time.Parse(time.RFC3339Nano, wire.LeaseExpiresAt)
	if err != nil {
		return Claim{}, fmt.Errorf("invalid lease expiry: %w", err)
	}
	return Claim{
		Request:              wire.Request,
		LeaseExpiresAt:       expiresAt,
		RepositoryCapability: wire.RepositoryCapability,
	}, nil
}

func (c *Client) Heartbeat(ctx context.Context, assignment Assignment) (Heartbeat, error) {
	var heartbeat Heartbeat
	status, err := c.postJSONStatus(
		ctx,
		fmt.Sprintf(
			"/api/executions/%s/attempts/%d/heartbeat",
			assignment.ExecutionID,
			assignment.AttemptNumber,
		),
		nil,
		&heartbeat,
	)
	if err != nil {
		return Heartbeat{}, err
	}
	if status != http.StatusOK && status != http.StatusConflict {
		return Heartbeat{}, fmt.Errorf("heartbeat returned HTTP %d", status)
	}
	if heartbeat.Status == "" {
		return Heartbeat{}, errors.New("heartbeat response is missing status")
	}
	return heartbeat, nil
}

func (c *Client) SubmitResult(
	ctx context.Context,
	assignment Assignment,
	result protocol.ResultV1,
) (Submission, error) {
	if err := result.Validate(); err != nil {
		return Submission{}, err
	}
	var submission Submission
	if err := c.postJSON(
		ctx,
		fmt.Sprintf(
			"/api/executions/%s/attempts/%d/result",
			assignment.ExecutionID,
			assignment.AttemptNumber,
		),
		result,
		&submission,
		http.StatusAccepted,
	); err != nil {
		return Submission{}, err
	}
	if submission.Status != "accepted" && submission.Status != "duplicate" {
		return Submission{}, fmt.Errorf("unexpected submission status %q", submission.Status)
	}
	return submission, nil
}

func (c *Client) postJSON(
	ctx context.Context,
	path string,
	body any,
	target any,
	expectedStatus int,
) error {
	status, err := c.postJSONStatus(ctx, path, body, target)
	if err != nil {
		return err
	}
	if status != expectedStatus {
		return fmt.Errorf("%s returned HTTP %d", path, status)
	}
	return nil
}

func (c *Client) postJSONStatus(
	ctx context.Context,
	path string,
	body any,
	target any,
) (int, error) {
	if strings.TrimSpace(c.BaseURL) == "" {
		return 0, errors.New("control plane URL is required")
	}
	if c.Token == "" {
		return 0, errors.New("control plane token is required")
	}

	var payload []byte
	var err error
	if body != nil {
		payload, err = json.Marshal(body)
		if err != nil {
			return 0, err
		}
	}

	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		strings.TrimRight(c.BaseURL, "/")+path,
		bytes.NewReader(payload),
	)
	if err != nil {
		return 0, err
	}
	request.Header.Set("Authorization", "Bearer "+c.Token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")

	client := c.HTTP
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()

	bodyBytes, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return response.StatusCode, err
	}
	if target != nil && len(bodyBytes) > 0 {
		if err := json.Unmarshal(bodyBytes, target); err != nil {
			return response.StatusCode, fmt.Errorf("decode response: %w", err)
		}
	}
	if response.StatusCode >= 500 {
		return response.StatusCode, fmt.Errorf(
			"control plane returned HTTP %d",
			response.StatusCode,
		)
	}
	return response.StatusCode, nil
}
