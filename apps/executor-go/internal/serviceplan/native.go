package serviceplan

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	defaultPersistence      = "auto"
	defaultSetupMode        = "auto"
	defaultPortEnv          = "PORT"
	defaultReadinessTimeout = 5
)

var (
	serviceNamePattern = regexp.MustCompile(`^[a-z][a-z0-9_-]*$`)
	composeNamePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)
	urlSchemePattern   = regexp.MustCompile(`^[a-z][a-z0-9+.-]*$`)
	envKeyPattern      = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
)

type NativeCompiler struct{}

func NewNativeCompiler() *NativeCompiler {
	return &NativeCompiler{}
}

type configFile struct {
	Version  *int           `yaml:"version"`
	Scenario scenarioConfig `yaml:"scenario"`
	Subject  subjectConfig  `yaml:"subject"`
}

type scenarioConfig struct {
	Path *string `yaml:"path"`
}

type subjectConfig struct {
	Persistence *string       `yaml:"persistence"`
	Setup       setupConfig   `yaml:"setup"`
	Services    []serviceSpec `yaml:"services"`
}

type setupConfig struct {
	Mode *string `yaml:"mode"`
}

type serviceSpec struct {
	Name       *string          `yaml:"name"`
	Type       *string          `yaml:"type"`
	Runtime    *string          `yaml:"runtime"`
	Entrypoint *string          `yaml:"entrypoint"`
	Args       *[]string        `yaml:"args"`
	PortEnv    *string          `yaml:"port_env"`
	URLEnv     *string          `yaml:"url_env"`
	Readiness  *readinessConfig `yaml:"readiness"`

	Manifest   *string `yaml:"manifest"`
	Service    *string `yaml:"service"`
	TargetPort *int    `yaml:"target_port"`
	URLScheme  *string `yaml:"url_scheme"`
}

type readinessConfig struct {
	Type           *string `yaml:"type"`
	Path           *string `yaml:"path"`
	TimeoutSeconds *int    `yaml:"timeout_seconds"`
}

func (c *NativeCompiler) Compile(
	_ context.Context,
	subjectRoot string,
) (Plan, error) {
	path := filepath.Join(subjectRoot, "rundiff.yml")
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return Plan{SchemaVersion: SchemaVersion, Steps: []Step{}}, nil
	}
	if err != nil {
		return Plan{}, fmt.Errorf("open rundiff.yml: %w", err)
	}
	defer file.Close()

	decoder := yaml.NewDecoder(io.LimitReader(file, 256*1024))
	decoder.KnownFields(true)

	var config configFile
	if err := decoder.Decode(&config); err != nil {
		return Plan{}, fmt.Errorf("invalid rundiff.yml: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return Plan{}, errors.New("invalid rundiff.yml: multiple YAML documents are not supported")
		}
		return Plan{}, fmt.Errorf("invalid rundiff.yml: %w", err)
	}

	if err := validateConfig(config); err != nil {
		return Plan{}, err
	}

	steps := make([]Step, 0, len(config.Subject.Services)*3)
	for index, service := range config.Subject.Services {
		serviceSteps, err := compileService(service, index)
		if err != nil {
			return Plan{}, err
		}
		steps = append(steps, serviceSteps...)
	}
	return Plan{SchemaVersion: SchemaVersion, Steps: steps}, nil
}

func validateConfig(config configFile) error {
	if config.Version == nil {
		return errors.New("rundiff.yml must declare version: 1")
	}
	if *config.Version != 1 {
		return fmt.Errorf("unsupported rundiff.yml version %d", *config.Version)
	}
	if config.Scenario.Path != nil &&
		!strings.HasPrefix(*config.Scenario.Path, "/") {
		return errors.New(
			"scenario.path must be an absolute HTTP path starting with /",
		)
	}

	persistence := defaultPersistence
	if config.Subject.Persistence != nil {
		persistence = *config.Subject.Persistence
	}
	if persistence != "auto" &&
		persistence != "postgresql" &&
		persistence != "sqlite" {
		return fmt.Errorf(
			"unsupported subject.persistence %q",
			persistence,
		)
	}

	setupMode := defaultSetupMode
	if config.Subject.Setup.Mode != nil {
		setupMode = *config.Subject.Setup.Mode
	}
	if setupMode != "auto" {
		return fmt.Errorf(
			"unsupported subject.setup.mode %q",
			setupMode,
		)
	}

	names := map[string]struct{}{}
	urlEnvs := map[string]struct{}{}
	for index, service := range config.Subject.Services {
		name, err := requiredString(service.Name, index, "name")
		if err != nil {
			return err
		}
		if !serviceNamePattern.MatchString(name) {
			return fmt.Errorf(
				"subject.services[%d].name is invalid",
				index,
			)
		}
		if _, exists := names[name]; exists {
			return fmt.Errorf("duplicate subject.services name %q", name)
		}
		names[name] = struct{}{}

		urlEnv, err := requiredString(service.URLEnv, index, "url_env")
		if err != nil {
			return err
		}
		if !envKeyPattern.MatchString(urlEnv) {
			return fmt.Errorf(
				"subject.services[%d].url_env is invalid",
				index,
			)
		}
		if _, exists := urlEnvs[urlEnv]; exists {
			return fmt.Errorf(
				"duplicate subject.services url_env %q",
				urlEnv,
			)
		}
		urlEnvs[urlEnv] = struct{}{}
	}
	return nil
}

func compileService(service serviceSpec, index int) ([]Step, error) {
	serviceType, err := requiredString(service.Type, index, "type")
	if err != nil {
		return nil, err
	}
	switch serviceType {
	case "process":
		return compileProcess(service, index)
	case "compose":
		return compileCompose(service, index)
	default:
		return nil, fmt.Errorf(
			"unsupported subject.services[%d].type %q",
			index,
			serviceType,
		)
	}
}

func compileProcess(service serviceSpec, index int) ([]Step, error) {
	if service.Manifest != nil ||
		service.Service != nil ||
		service.TargetPort != nil ||
		service.URLScheme != nil {
		return nil, fmt.Errorf(
			"subject.services[%d] mixes process and compose keys",
			index,
		)
	}
	name, _ := requiredString(service.Name, index, "name")
	runtime, err := requiredString(service.Runtime, index, "runtime")
	if err != nil {
		return nil, err
	}
	if runtime != "ruby" && runtime != "node" {
		return nil, fmt.Errorf(
			"unsupported subject.services[%d].runtime %q",
			index,
			runtime,
		)
	}
	entrypoint, err := requiredString(
		service.Entrypoint,
		index,
		"entrypoint",
	)
	if err != nil {
		return nil, err
	}
	if err := validateRelativePath(entrypoint); err != nil {
		return nil, fmt.Errorf(
			"subject.services[%d].entrypoint: %w",
			index,
			err,
		)
	}
	args := make([]any, 0)
	if service.Args != nil {
		for _, arg := range *service.Args {
			args = append(args, arg)
		}
	}
	portEnv := defaultPortEnv
	if service.PortEnv != nil {
		portEnv = *service.PortEnv
	}
	if !envKeyPattern.MatchString(portEnv) {
		return nil, fmt.Errorf(
			"subject.services[%d].port_env is invalid",
			index,
		)
	}
	urlEnv, _ := requiredString(service.URLEnv, index, "url_env")
	if portEnv == urlEnv {
		return nil, fmt.Errorf(
			"subject.services[%d].port_env and url_env must differ",
			index,
		)
	}
	readiness, err := compileReadiness(service, index, name, urlEnv)
	if err != nil {
		return nil, err
	}
	return []Step{
		{
			Phase:      "start_services",
			Operation:  "process.start",
			Provenance: "explicit",
			Details: map[string]any{
				"name":       name,
				"runtime":    runtime,
				"entrypoint": entrypoint,
				"args":       args,
				"port_env":   portEnv,
				"url_env":    urlEnv,
			},
		},
		readiness,
		{
			Phase:      "stop_services",
			Operation:  "process.stop",
			Provenance: "explicit",
			Details:    map[string]any{"name": name},
		},
	}, nil
}

func compileCompose(service serviceSpec, index int) ([]Step, error) {
	if service.Runtime != nil ||
		service.Entrypoint != nil ||
		service.Args != nil ||
		service.PortEnv != nil {
		return nil, fmt.Errorf(
			"subject.services[%d] mixes compose and process keys",
			index,
		)
	}
	name, _ := requiredString(service.Name, index, "name")
	manifest, err := requiredString(service.Manifest, index, "manifest")
	if err != nil {
		return nil, err
	}
	if err := validateRelativePath(manifest); err != nil {
		return nil, fmt.Errorf(
			"subject.services[%d].manifest: %w",
			index,
			err,
		)
	}
	composeService, err := requiredString(
		service.Service,
		index,
		"service",
	)
	if err != nil {
		return nil, err
	}
	if !composeNamePattern.MatchString(composeService) {
		return nil, fmt.Errorf(
			"subject.services[%d].service is invalid",
			index,
		)
	}
	if service.TargetPort == nil ||
		*service.TargetPort < 1 ||
		*service.TargetPort > 65535 {
		return nil, fmt.Errorf(
			"subject.services[%d].target_port must be 1..65535",
			index,
		)
	}
	urlScheme, err := requiredString(
		service.URLScheme,
		index,
		"url_scheme",
	)
	if err != nil {
		return nil, err
	}
	if !urlSchemePattern.MatchString(urlScheme) {
		return nil, fmt.Errorf(
			"subject.services[%d].url_scheme is invalid",
			index,
		)
	}
	urlEnv, _ := requiredString(service.URLEnv, index, "url_env")
	readiness, err := compileReadiness(service, index, name, urlEnv)
	if err != nil {
		return nil, err
	}
	return []Step{
		{
			Phase:      "start_services",
			Operation:  "compose.run",
			Provenance: "explicit",
			Details: map[string]any{
				"name":        name,
				"manifest":    manifest,
				"service":     composeService,
				"target_port": float64(*service.TargetPort),
				"url_scheme":  urlScheme,
				"url_env":     urlEnv,
			},
		},
		readiness,
		{
			Phase:      "stop_services",
			Operation:  "compose.stop",
			Provenance: "explicit",
			Details:    map[string]any{"name": name},
		},
	}, nil
}

func compileReadiness(
	service serviceSpec,
	index int,
	name string,
	urlEnv string,
) (Step, error) {
	if service.Readiness == nil {
		return Step{}, fmt.Errorf(
			"subject.services[%d] must declare readiness",
			index,
		)
	}
	readinessType, err := requiredReadinessString(
		service.Readiness.Type,
		index,
		"type",
	)
	if err != nil {
		return Step{}, err
	}
	if readinessType != "http" && readinessType != "tcp" {
		return Step{}, fmt.Errorf(
			"unsupported subject.services[%d].readiness.type %q",
			index,
			readinessType,
		)
	}
	timeout := defaultReadinessTimeout
	if service.Readiness.TimeoutSeconds != nil {
		timeout = *service.Readiness.TimeoutSeconds
	}
	if timeout < 1 || timeout > 60 {
		return Step{}, fmt.Errorf(
			"subject.services[%d].readiness.timeout_seconds must be 1..60",
			index,
		)
	}
	details := map[string]any{
		"name":            name,
		"url_env":         urlEnv,
		"timeout_seconds": float64(timeout),
	}
	if readinessType == "http" {
		if service.Readiness.Path == nil ||
			!strings.HasPrefix(*service.Readiness.Path, "/") {
			return Step{}, fmt.Errorf(
				"subject.services[%d].readiness.path must start with /",
				index,
			)
		}
		details["path"] = *service.Readiness.Path
	} else if service.Readiness.Path != nil {
		return Step{}, fmt.Errorf(
			"subject.services[%d].readiness.path is only valid for HTTP",
			index,
		)
	}
	return Step{
		Phase:      "healthcheck",
		Operation:  readinessType + ".wait_ready",
		Provenance: "explicit",
		Details:    details,
	}, nil
}

func requiredString(
	value *string,
	index int,
	key string,
) (string, error) {
	if value == nil || *value == "" {
		return "", fmt.Errorf(
			"subject.services[%d] must declare %s",
			index,
			key,
		)
	}
	return *value, nil
}

func requiredReadinessString(
	value *string,
	index int,
	key string,
) (string, error) {
	if value == nil || *value == "" {
		return "", fmt.Errorf(
			"subject.services[%d].readiness must declare %s",
			index,
			key,
		)
	}
	return *value, nil
}

func validateRelativePath(value string) error {
	if value == "" {
		return errors.New("must be a non-empty repository-relative path")
	}
	if filepath.IsAbs(value) {
		return errors.New("must be repository-relative")
	}
	for _, component := range strings.FieldsFunc(
		value,
		func(r rune) bool { return r == '/' || r == '\\' },
	) {
		if component == ".." {
			return errors.New("must not contain ..")
		}
	}
	return nil
}
