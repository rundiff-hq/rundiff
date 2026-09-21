package journal

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Entry struct {
	Sequence       uint64    `json:"sequence"`
	At             time.Time `json:"at"`
	Kind           string    `json:"kind"`
	ExecutionID    string    `json:"execution_id"`
	AttemptNumber  int       `json:"attempt_number"`
	Phase          string    `json:"phase,omitempty"`
	Role           string    `json:"role,omitempty"`
	ResourceKind   string    `json:"resource_kind,omitempty"`
	Resource       string    `json:"resource,omitempty"`
	Message        string    `json:"message,omitempty"`
	Implementation string    `json:"implementation,omitempty"`
	DurationMillis int64     `json:"duration_ms,omitempty"`
	Outcome        string    `json:"outcome,omitempty"`
}

type Recorder interface {
	Append(Entry) error
}

type Journal struct {
	mu       sync.Mutex
	file     *os.File
	sequence uint64
	now      func() time.Time
}

func Open(path string) (*Journal, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}

	return &Journal{
		file: file,
		now:  func() time.Time { return time.Now().UTC() },
	}, nil
}

func (j *Journal) Append(entry Entry) error {
	j.mu.Lock()
	defer j.mu.Unlock()

	if j.file == nil {
		return fmt.Errorf("resource journal is closed")
	}

	j.sequence++
	entry.Sequence = j.sequence
	if entry.At.IsZero() {
		entry.At = j.now()
	}

	body, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	body = append(body, '\n')

	if _, err := j.file.Write(body); err != nil {
		return err
	}
	return j.file.Sync()
}

func (j *Journal) Close() error {
	j.mu.Lock()
	defer j.mu.Unlock()

	if j.file == nil {
		return nil
	}
	err := j.file.Close()
	j.file = nil
	return err
}
