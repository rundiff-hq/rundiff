package protocol

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestRequestV1GoldenFixture(t *testing.T) {
	path := fixturePath(t, "request.json")
	request, err := LoadRequest(path)
	if err != nil {
		t.Fatalf("LoadRequest: %v", err)
	}

	actual, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	assertJSONSemanticEqual(t, mustRead(t, path), actual)
}

func TestResultV1GoldenFixtures(t *testing.T) {
	for _, name := range []string{
		"result-allow.json",
		"result-block.json",
		"result-failure.json",
	} {
		t.Run(name, func(t *testing.T) {
			path := fixturePath(t, name)
			result, err := LoadResult(path)
			if err != nil {
				t.Fatalf("LoadResult: %v", err)
			}

			actual, err := json.Marshal(result)
			if err != nil {
				t.Fatalf("Marshal: %v", err)
			}
			assertJSONSemanticEqual(t, mustRead(t, path), actual)
		})
	}
}

func TestRequestV1AcceptsUnknownAdditiveFields(t *testing.T) {
	input := []byte(`{
		"schema_version":"1",
		"execution_id":"exec-1",
		"scenario_id":"scenario-1",
		"baseline_sha":"aaa",
		"candidate_sha":"bbb",
		"attempt_number":1,
		"context":{"repository":"demo/shop","future_field":"ignored"},
		"future_top_level":{"value":true}
	}`)

	if _, err := DecodeRequest(bytes.NewReader(input)); err != nil {
		t.Fatalf("DecodeRequest rejected additive fields: %v", err)
	}
}

func fixturePath(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join("..", "..", "..", "..", "protocol", "executor", "v1", "fixtures", name)
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s): %v", path, err)
	}
	return body
}

func assertJSONSemanticEqual(t *testing.T, expected, actual []byte) {
	t.Helper()

	var left any
	var right any
	if err := json.Unmarshal(expected, &left); err != nil {
		t.Fatalf("unmarshal expected JSON: %v", err)
	}
	if err := json.Unmarshal(actual, &right); err != nil {
		t.Fatalf("unmarshal actual JSON: %v", err)
	}
	if !reflect.DeepEqual(left, right) {
		t.Fatalf("JSON differs\nexpected: %s\nactual:   %s", expected, actual)
	}
}
