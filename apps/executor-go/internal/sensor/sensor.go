package sensor

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/serviceplan"
)

const SchemaVersion = "1"

var railsSubjectOwnedMarkers = []string{
	"lib/rundiff/rails/evidence_collector.rb",
	"lib/rundiff/rails/execution_quiescence.rb",
	"app/models/current.rb",
	"app/models/rundiff_evidence_event.rb",
	"app/models/rundiff_execution_work_item.rb",
}

type Spec struct {
	Adapter string
	Mode    string
	Runtime string
	Command      []string
	TargetURLEnv string
}

type Registry struct {
	ToolRoot string
}

func NewRegistry(toolRoot string) Registry {
	return Registry{ToolRoot: toolRoot}
}

func (r Registry) Resolve(root string) (Spec, error) {
	rails := regularFile(filepath.Join(root, "config", "environment.rb"))
	node := regularFile(filepath.Join(root, "package.json"))
	if rails && node {
		return Spec{}, fmt.Errorf("ambiguous runtime sensor for %s", root)
	}
	if node {
		urlEnv, err := serviceplan.NodeScenarioURLEnv(root)
		if err != nil {
			return Spec{}, err
		}
		return Spec{
			Adapter:      "node",
			Mode:         "tool_owned_node_http",
			Runtime:      "node",
			Command:      []string{"node", filepath.Join(r.ToolRoot, "script", "rundiff_capture_node.mjs")},
			TargetURLEnv: urlEnv,
		}, nil
	}
	if rails {
		mode := "tool_owned_portable_rails"
		script := "rundiff_capture_portable_rails.rb"
		if subjectOwnedRails(root) {
			mode = "subject_owned_rails"
			script = "rundiff_capture_subject.rb"
		}
		return Spec{
			Adapter: "rails",
			Mode:    mode,
			Runtime: "ruby",
			Command: []string{"ruby", filepath.Join(r.ToolRoot, "script", script)},
		}, nil
	}
	return Spec{}, fmt.Errorf("no supported runtime sensor for %s", root)
}

type ExpectedCapture struct {
	RunID      string
	ScenarioID string
	Subject    string
	Label      string
	SHA        string
	Spec       Spec
}

func ValidateCapture(body []byte, expected ExpectedCapture) error {
	var capture map[string]any
	if err := json.Unmarshal(body, &capture); err != nil {
		return fmt.Errorf("invalid JSON: %w", err)
	}

	for key, want := range map[string]string{
		"id":          expected.Label,
		"run_id":      expected.RunID,
		"scenario_id": expected.ScenarioID,
		"subject":     expected.Subject,
		"ref":         expected.Label,
		"sha":         expected.SHA,
	} {
		if got, ok := capture[key].(string); !ok || got != want {
			return fmt.Errorf("%s = %v, want %q", key, capture[key], want)
		}
	}
	if executionID, ok := capture["execution_id"].(string); !ok || executionID == "" {
		return errors.New("execution_id must be a non-empty string")
	}
	status, ok := capture["status"].(string)
	if !ok || (status != "passed" && status != "failed") {
		return fmt.Errorf("status = %v, want passed or failed", capture["status"])
	}
	if _, ok := capture["measurements"].(map[string]any); !ok {
		return errors.New("measurements must be an object")
	}
	if _, ok := capture["attributions"].(map[string]any); !ok {
		return errors.New("attributions must be an object")
	}
	if _, ok := capture["durable_observations"].([]any); !ok {
		return errors.New("durable_observations must be an array")
	}

	identity, ok := capture["sensor"].(map[string]any)
	if !ok {
		return errors.New("sensor must be an object")
	}
	for key, want := range map[string]string{
		"schema_version": SchemaVersion,
		"adapter":        expected.Spec.Adapter,
		"mode":           expected.Spec.Mode,
		"runtime":        expected.Spec.Runtime,
	} {
		if got, ok := identity[key].(string); !ok || got != want {
			return fmt.Errorf("sensor.%s = %v, want %q", key, identity[key], want)
		}
	}
	return nil
}

func subjectOwnedRails(root string) bool {
	for _, marker := range railsSubjectOwnedMarkers {
		if !regularFile(filepath.Join(root, marker)) {
			return false
		}
	}
	return true
}

func regularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
