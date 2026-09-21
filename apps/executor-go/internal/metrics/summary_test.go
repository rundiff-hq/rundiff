package metrics

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSummarizeFilesGroupsAndCalculatesPercentiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metrics.jsonl")
	body := "" +
		"{\"schema_version\":\"1\",\"implementation\":\"go\",\"phase\":\"clone\",\"duration_ms\":100,\"outcome\":\"ok\"}\n" +
		"{\"schema_version\":\"1\",\"implementation\":\"go\",\"phase\":\"clone\",\"duration_ms\":200,\"outcome\":\"ok\"}\n" +
		"{\"schema_version\":\"1\",\"implementation\":\"go\",\"phase\":\"clone\",\"duration_ms\":500,\"outcome\":\"ok\"}\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	summaries, err := SummarizeFiles([]string{path})
	if err != nil {
		t.Fatalf("SummarizeFiles: %v", err)
	}
	if len(summaries) != 1 {
		t.Fatalf("expected one summary, got %d", len(summaries))
	}
	got := summaries[0]
	if got.Count != 3 ||
		got.MedianMillis != 200 ||
		got.P95Millis != 500 ||
		got.MinMillis != 100 ||
		got.MaxMillis != 500 {
		t.Fatalf("unexpected summary: %+v", got)
	}
}
