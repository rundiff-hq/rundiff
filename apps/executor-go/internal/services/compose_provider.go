package services

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const (
	composeProtocolVersion = 1
	maxManifestBytes       = 128 * 1024
	maxResponseBytes       = 256 * 1024
)

type IsolatedComposeProvider struct {
	SocketPath string
}

func ComposeProviderFromEnv() ComposeProvider {
	socketPath := strings.TrimSpace(
		os.Getenv("RUNDIFF_COMPOSE_PROVIDER_SOCKET"),
	)
	if socketPath == "" {
		return nil
	}
	return &IsolatedComposeProvider{SocketPath: socketPath}
}

func (p *IsolatedComposeProvider) Start(
	ctx context.Context,
	executionID string,
	role string,
	root string,
	details map[string]any,
) (ComposeStarted, error) {
	manifestValue, err := stringDetail(details, "manifest")
	if err != nil {
		return ComposeStarted{}, err
	}
	serviceName, err := stringDetail(details, "name")
	if err != nil {
		return ComposeStarted{}, err
	}
	manifest, err := readManifest(root, manifestValue, serviceName)
	if err != nil {
		return ComposeStarted{}, err
	}

	payload, err := p.request(ctx, "start", map[string]any{
		"execution_id": executionID,
		"role":         role,
		"manifest":     manifest,
		"details":      details,
	})
	if err != nil {
		return ComposeStarted{}, err
	}

	handle, ok := payload["handle_id"].(string)
	if !ok || handle == "" {
		return ComposeStarted{}, errors.New(
			"Compose provider start response is missing handle_id",
		)
	}
	host, ok := payload["host"].(string)
	if !ok || host == "" {
		return ComposeStarted{}, errors.New(
			"Compose provider start response is missing host",
		)
	}
	portValue, ok := payload["port"].(float64)
	if !ok || portValue < 1 || portValue > 65535 {
		return ComposeStarted{}, fmt.Errorf(
			"Compose provider returned invalid port %v",
			payload["port"],
		)
	}

	return ComposeStarted{
		Handle: handle,
		Host:   host,
		Port:   int(portValue),
	}, nil
}

func (p *IsolatedComposeProvider) Stop(
	ctx context.Context,
	handle string,
) error {
	_, err := p.request(
		ctx,
		"stop",
		map[string]any{"handle_id": handle},
	)
	return err
}

func (p *IsolatedComposeProvider) Diagnostics(
	ctx context.Context,
	handle string,
) string {
	payload, err := p.request(
		ctx,
		"diagnostics",
		map[string]any{"handle_id": handle},
	)
	if err != nil {
		return ""
	}
	content, _ := payload["content"].(string)
	return content
}

func (p *IsolatedComposeProvider) request(
	ctx context.Context,
	operation string,
	payload map[string]any,
) (map[string]any, error) {
	requestID, err := requestID()
	if err != nil {
		return nil, err
	}
	var dialer net.Dialer
	connection, err := dialer.DialContext(ctx, "unix", p.SocketPath)
	if err != nil {
		return nil, fmt.Errorf(
			"isolated Compose provider unavailable at %s: %w",
			p.SocketPath,
			err,
		)
	}
	defer connection.Close()

	requestBody, err := json.Marshal(map[string]any{
		"protocol_version": composeProtocolVersion,
		"request_id":       requestID,
		"operation":        operation,
		"payload":          payload,
	})
	if err != nil {
		return nil, err
	}
	if _, err := connection.Write(append(requestBody, '\n')); err != nil {
		return nil, err
	}

	reader := bufio.NewReader(connection)
	raw, err := reader.ReadBytes('\n')
	if err != nil {
		return nil, fmt.Errorf("read Compose provider response: %w", err)
	}
	if len(raw) > maxResponseBytes {
		return nil, errors.New("Compose provider response exceeds limit")
	}

	var response struct {
		RequestID string         `json:"request_id"`
		OK        bool           `json:"ok"`
		Payload   map[string]any `json:"payload"`
		Error     struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return nil, fmt.Errorf("invalid Compose provider response: %w", err)
	}
	if response.RequestID != requestID {
		return nil, errors.New(
			"Compose provider returned mismatched request_id",
		)
	}
	if !response.OK {
		message := response.Error.Message
		if message == "" {
			message = "Compose provider request failed"
		}
		return nil, errors.New(message)
	}
	if response.Payload == nil {
		response.Payload = map[string]any{}
	}
	return response.Payload, nil
}

func readManifest(
	root string,
	value string,
	serviceName string,
) (string, error) {
	rootResolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	path, err := filepath.EvalSymlinks(
		filepath.Join(rootResolved, value),
	)
	if err != nil {
		return "", fmt.Errorf(
			"Compose service %q manifest is unavailable: %w",
			serviceName,
			err,
		)
	}
	prefix := rootResolved + string(os.PathSeparator)
	if !strings.HasPrefix(path, prefix) {
		return "", fmt.Errorf(
			"Compose service %q manifest must resolve inside repository",
			serviceName,
		)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf(
			"Compose service %q manifest must be a regular file",
			serviceName,
		)
	}
	if info.Size() > maxManifestBytes {
		return "", fmt.Errorf(
			"Compose service %q manifest exceeds %d bytes",
			serviceName,
			maxManifestBytes,
		)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if !utf8.Valid(body) {
		return "", fmt.Errorf(
			"Compose service %q manifest must be UTF-8",
			serviceName,
		)
	}
	return string(body), nil
}

func requestID() (string, error) {
	var bytes [12]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes[:]), nil
}
