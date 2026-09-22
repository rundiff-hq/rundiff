package metrics

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestJSONLRecordsSafePhaseMetric(t *testing.T) {
	path := filepath.Join(t.TempDir(), "phase-metrics.jsonl")
	recorder, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := recorder.Record(Event{
		ExecutionID:    "exec-1",
		AttemptNumber:  2,
		Implementation: "go",
		Phase:          "clone",
		DurationMillis: 123,
		Outcome:        "ok",
	}); err != nil {
		t.Fatalf("Record: %v", err)
	}
	if err := recorder.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open metric file: %v", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	if !scanner.Scan() {
		t.Fatal("expected one metric")
	}
	var event Event
	if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if event.SchemaVersion != SchemaVersion ||
		event.Implementation != "go" ||
		event.Phase != "clone" ||
		event.DurationMillis != 123 {
		t.Fatalf("unexpected metric: %+v", event)
	}
}
