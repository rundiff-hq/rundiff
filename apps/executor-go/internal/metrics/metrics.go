package metrics

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const SchemaVersion = "1"

type Event struct {
	SchemaVersion  string    `json:"schema_version"`
	At             time.Time `json:"at"`
	ExecutionID    string    `json:"execution_id"`
	AttemptNumber  int       `json:"attempt_number"`
	Implementation string    `json:"implementation"`
	Phase          string    `json:"phase"`
	Role           string    `json:"role,omitempty"`
	DurationMillis int64     `json:"duration_ms"`
	Outcome        string    `json:"outcome"`
	ErrorClass     string    `json:"error_class,omitempty"`
}

type Recorder interface {
	Record(Event) error
}

type Nop struct{}

func (Nop) Record(Event) error { return nil }

type JSONL struct {
	mu   sync.Mutex
	file *os.File
	now  func() time.Time
}

func Open(path string) (*JSONL, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return &JSONL{
		file: file,
		now:  func() time.Time { return time.Now().UTC() },
	}, nil
}

func (r *JSONL) Record(event Event) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.file == nil {
		return fmt.Errorf("phase metrics recorder is closed")
	}
	if event.SchemaVersion == "" {
		event.SchemaVersion = SchemaVersion
	}
	if event.At.IsZero() {
		event.At = r.now()
	}

	body, err := json.Marshal(event)
	if err != nil {
		return err
	}
	body = append(body, '\n')
	if _, err := r.file.Write(body); err != nil {
		return err
	}
	return r.file.Sync()
}

func (r *JSONL) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.file == nil {
		return nil
	}
	err := r.file.Close()
	r.file = nil
	return err
}
