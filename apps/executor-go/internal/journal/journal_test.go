package journal

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestJournalAppendsDurableJSONL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "resource-journal.jsonl")
	journal, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}

	for _, entry := range []Entry{
		{Kind: "phase_started", ExecutionID: "exec-1", AttemptNumber: 1, Phase: "Prepare"},
		{Kind: "resource_created", ExecutionID: "exec-1", AttemptNumber: 1, ResourceKind: "workspace", Resource: "/tmp/example"},
	} {
		if err := journal.Append(entry); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	if err := journal.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open journal: %v", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	var entries []Entry
	for scanner.Scan() {
		var entry Entry
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
			t.Fatalf("Unmarshal journal entry: %v", err)
		}
		entries = append(entries, entry)
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan journal: %v", err)
	}

	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
	if entries[0].Sequence != 1 || entries[1].Sequence != 2 {
		t.Fatalf("unexpected journal sequences: %+v", entries)
	}
}
