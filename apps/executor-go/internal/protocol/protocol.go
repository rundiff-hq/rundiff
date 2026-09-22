package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const SchemaVersion = "1"

type RequestV1 struct {
	SchemaVersion string    `json:"schema_version"`
	ExecutionID   string    `json:"execution_id"`
	ScenarioID    string    `json:"scenario_id"`
	BaselineSHA   string    `json:"baseline_sha"`
	CandidateSHA  string    `json:"candidate_sha"`
	AttemptNumber int       `json:"attempt_number"`
	Context       ContextV1 `json:"context"`
}

type ContextV1 struct {
	Repository          string `json:"repository,omitempty"`
	PullRequestNumber   int    `json:"pull_request_number,omitempty"`
	BaselineRef         string `json:"baseline_ref,omitempty"`
	CandidateRef        string `json:"candidate_ref,omitempty"`
	CandidateRepository string `json:"candidate_repository,omitempty"`
}

func (r RequestV1) Validate() error {
	if r.SchemaVersion != SchemaVersion {
		return fmt.Errorf("unsupported executor request schema %q", r.SchemaVersion)
	}
	if r.ExecutionID == "" {
		return errors.New("executor request execution_id must be non-empty")
	}
	if r.ScenarioID == "" {
		return errors.New("executor request scenario_id must be non-empty")
	}
	if r.BaselineSHA == "" {
		return errors.New("executor request baseline_sha must be non-empty")
	}
	if r.CandidateSHA == "" {
		return errors.New("executor request candidate_sha must be non-empty")
	}
	if r.AttemptNumber < 1 {
		return errors.New("executor request attempt_number must be positive")
	}
	return nil
}

type ResultV1 struct {
	SchemaVersion string          `json:"schema_version"`
	Status        string          `json:"status"`
	Payload       json.RawMessage `json:"payload"`
	ErrorClass    *string         `json:"error_class"`
	ErrorMessage  *string         `json:"error_message"`
}

func (r ResultV1) Validate() error {
	if r.SchemaVersion != SchemaVersion {
		return fmt.Errorf("unsupported executor result schema %q", r.SchemaVersion)
	}
	if r.Status != "succeeded" && r.Status != "failed" {
		return fmt.Errorf("unsupported executor result status %q", r.Status)
	}
	if len(r.Payload) == 0 {
		return errors.New("executor result payload must be present")
	}
	return nil
}

func Failed(errorClass, message string) ResultV1 {
	return ResultV1{
		SchemaVersion: SchemaVersion,
		Status:        "failed",
		Payload:       json.RawMessage("null"),
		ErrorClass:    stringPointer(errorClass),
		ErrorMessage:  stringPointer(message),
	}
}

func DecodeRequest(reader io.Reader) (RequestV1, error) {
	var request RequestV1
	if err := decodeOne(reader, &request); err != nil {
		return RequestV1{}, fmt.Errorf("decode executor request: %w", err)
	}
	if err := request.Validate(); err != nil {
		return RequestV1{}, err
	}
	return request, nil
}

func DecodeResult(reader io.Reader) (ResultV1, error) {
	var result ResultV1
	if err := decodeOne(reader, &result); err != nil {
		return ResultV1{}, fmt.Errorf("decode executor result: %w", err)
	}
	if err := result.Validate(); err != nil {
		return ResultV1{}, err
	}
	return result, nil
}

func LoadRequest(path string) (RequestV1, error) {
	file, err := os.Open(path)
	if err != nil {
		return RequestV1{}, err
	}
	defer file.Close()
	return DecodeRequest(file)
}

func LoadResult(path string) (ResultV1, error) {
	file, err := os.Open(path)
	if err != nil {
		return ResultV1{}, err
	}
	defer file.Close()
	return DecodeResult(file)
}

func WriteRequest(path string, request RequestV1) error {
	if err := request.Validate(); err != nil {
		return err
	}
	return writeJSONAtomic(path, request)
}

func WriteResult(path string, result ResultV1) error {
	if err := result.Validate(); err != nil {
		return err
	}
	return writeJSONAtomic(path, result)
}

func decodeOne(reader io.Reader, target any) error {
	decoder := json.NewDecoder(reader)
	if err := decoder.Decode(target); err != nil {
		return err
	}

	var trailing any
	err := decoder.Decode(&trailing)
	if !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("unexpected trailing JSON value")
		}
		return err
	}
	return nil
}

func writeJSONAtomic(path string, value any) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	var body bytes.Buffer
	encoder := json.NewEncoder(&body)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return err
	}

	file, err := os.CreateTemp(dir, ".rundiff-json-*")
	if err != nil {
		return err
	}
	tempPath := file.Name()
	defer os.Remove(tempPath)

	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(body.Bytes()); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}

	return os.Rename(tempPath, path)
}

func stringPointer(value string) *string {
	return &value
}
