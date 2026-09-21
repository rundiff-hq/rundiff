package serviceplan

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

const SchemaVersion = "1"

type Step struct {
	Phase      string         `json:"phase"`
	Operation  string         `json:"operation"`
	Provenance string         `json:"provenance"`
	Details    map[string]any `json:"details"`
}

type Plan struct {
	SchemaVersion string `json:"schema_version"`
	Steps         []Step `json:"steps"`
}

func (p Plan) StepsFor(phase string) []Step {
	result := make([]Step, 0)
	for _, step := range p.Steps {
		if step.Phase == phase {
			result = append(result, step)
		}
	}
	return result
}

type Compiler interface {
	Compile(context.Context, string) (Plan, error)
}

type RubyCompiler struct {
	ToolRoot string
}

func NewRubyCompiler(toolRoot string) *RubyCompiler {
	return &RubyCompiler{ToolRoot: toolRoot}
}

func (c *RubyCompiler) Compile(
	ctx context.Context,
	subjectRoot string,
) (Plan, error) {
	script := filepath.Join(c.ToolRoot, "script", "compile_service_plan.rb")
	command := exec.CommandContext(ctx, "ruby", script, subjectRoot)
	command.Dir = c.ToolRoot
	command.Env = safeHostEnvironment()

	output, err := command.Output()
	if err != nil {
		return Plan{}, fmt.Errorf("compile service plan: %w", err)
	}

	var plan Plan
	if err := json.Unmarshal(output, &plan); err != nil {
		return Plan{}, fmt.Errorf("decode service plan: %w", err)
	}
	if plan.SchemaVersion != SchemaVersion {
		return Plan{}, fmt.Errorf(
			"unsupported service plan schema_version %q",
			plan.SchemaVersion,
		)
	}
	return plan, nil
}

func safeHostEnvironment() []string {
	keys := []string{
		"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
		"SSL_CERT_FILE", "SSL_CERT_DIR",
	}
	environment := make([]string, 0, len(keys))
	for _, key := range keys {
		if value, ok := os.LookupEnv(key); ok {
			environment = append(environment, key+"="+value)
		}
	}
	return environment
}
