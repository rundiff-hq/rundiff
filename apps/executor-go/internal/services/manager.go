package services

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/serviceplan"
)

const (
	readinessInterval = 50 * time.Millisecond
	stopTimeout       = 2 * time.Second
)

type ComposeStarted struct {
	Handle string
	Host   string
	Port   int
}

type ComposeProvider interface {
	Start(
		context.Context,
		string,
		string,
		string,
		map[string]any,
	) (ComposeStarted, error)
	Stop(context.Context, string) error
	Diagnostics(context.Context, string) string
}

type runningService struct {
	name       string
	kind       string
	cmd        *exec.Cmd
	handle     string
	host       string
	port       int
	urlEnv     string
	url        string
	stderrPath string
}

type Session struct {
	plan     serviceplan.Plan
	services []runningService
	stateDir string
}

type Manager struct {
	Compiler serviceplan.Compiler
	Compose  ComposeProvider
}

func NewManager(
	compiler serviceplan.Compiler,
	compose ComposeProvider,
) *Manager {
	return &Manager{Compiler: compiler, Compose: compose}
}

func (m *Manager) Start(
	ctx context.Context,
	request protocol.RequestV1,
	role string,
	root string,
	env map[string]string,
	recorder journal.Recorder,
) (any, map[string]string, error) {
	if m.Compiler == nil {
		return nil, nil, errors.New("service plan compiler is required")
	}
	plan, err := m.Compiler.Compile(ctx, root)
	if err != nil {
		return nil, nil, err
	}

	stateDir, err := os.MkdirTemp("", "rundiff-go-services-"+role+"-")
	if err != nil {
		return nil, nil, err
	}
	session := &Session{plan: plan, stateDir: stateDir}
	if err := recorder.Append(journal.Entry{
		Kind:          "resource_created",
		ExecutionID:   request.ExecutionID,
		AttemptNumber: request.AttemptNumber,
		ResourceKind:  "service_state",
		Resource:      stateDir,
	}); err != nil {
		_ = os.RemoveAll(stateDir)
		return nil, nil, err
	}
	captureEnv := map[string]string{}

	for _, step := range plan.StepsFor("start_services") {
		urlEnv, detailErr := stringDetail(step.Details, "url_env")
		if detailErr != nil {
			_ = m.Stop(
				context.Background(),
				request,
				role,
				root,
				mergeEnv(env, captureEnv),
				session,
				recorder,
			)
			return nil, nil, detailErr
		}
		if _, exists := env[urlEnv]; exists {
			_ = m.Stop(
				context.Background(),
				request,
				role,
				root,
				mergeEnv(env, captureEnv),
				session,
				recorder,
			)
			return nil, nil, fmt.Errorf(
				"service cannot overwrite environment %q",
				urlEnv,
			)
		}
		if _, exists := captureEnv[urlEnv]; exists {
			_ = m.Stop(
				context.Background(),
				request,
				role,
				root,
				mergeEnv(env, captureEnv),
				session,
				recorder,
			)
			return nil, nil, fmt.Errorf(
				"duplicate service url environment %q",
				urlEnv,
			)
		}

		service, startErr := m.startOne(
			ctx,
			request,
			role,
			root,
			mergeEnv(env, captureEnv),
			step,
			stateDir,
		)
		if startErr != nil {
			_ = m.Stop(
				context.Background(),
				request,
				role,
				root,
				mergeEnv(env, captureEnv),
				session,
				recorder,
			)
			return nil, nil, startErr
		}
		session.services = append(session.services, service)
		captureEnv[service.urlEnv] = service.url

		resource := service.handle
		if service.cmd != nil && service.cmd.Process != nil {
			resource = fmt.Sprintf("%d", service.cmd.Process.Pid)
		}
		_ = recorder.Append(journal.Entry{
			Kind:          "resource_created",
			ExecutionID:   request.ExecutionID,
			AttemptNumber: request.AttemptNumber,
			ResourceKind:  "service_" + service.kind,
			Resource:      resource,
		})
	}

	return session, captureEnv, nil
}

func (m *Manager) Ready(
	ctx context.Context,
	_ protocol.RequestV1,
	_ string,
	_ string,
	env map[string]string,
	sessionValue any,
) error {
	session, err := coerceSession(sessionValue)
	if err != nil || session == nil {
		return err
	}
	services := map[string]runningService{}
	for _, service := range session.services {
		services[service.name] = service
	}

	for _, step := range session.plan.StepsFor("healthcheck") {
		name, err := stringDetail(step.Details, "name")
		if err != nil {
			return err
		}
		service, ok := services[name]
		if !ok {
			return fmt.Errorf("readiness references service not started: %s", name)
		}
		switch step.Operation {
		case "http.wait_ready":
			if err := m.waitHTTP(ctx, service, step, env); err != nil {
				return err
			}
		case "tcp.wait_ready":
			if err := m.waitTCP(ctx, service, step); err != nil {
				return err
			}
		default:
			return fmt.Errorf(
				"unsupported service healthcheck operation %q",
				step.Operation,
			)
		}
	}
	return nil
}

func (m *Manager) Stop(
	ctx context.Context,
	request protocol.RequestV1,
	_ string,
	_ string,
	_ map[string]string,
	sessionValue any,
	recorder journal.Recorder,
) error {
	session, err := coerceSession(sessionValue)
	if err != nil || session == nil {
		return err
	}

	var failures []error
	if validationErr := validateStopPlan(session); validationErr != nil {
		failures = append(failures, validationErr)
	}
	for index := len(session.services) - 1; index >= 0; index-- {
		service := session.services[index]
		var stopErr error
		switch service.kind {
		case "process":
			stopErr = stopProcess(ctx, service)
		case "compose":
			if m.Compose == nil {
				stopErr = fmt.Errorf(
					"compose provider unavailable while stopping %q",
					service.name,
				)
			} else {
				stopErr = m.Compose.Stop(ctx, service.handle)
			}
		}
		if stopErr != nil {
			failures = append(failures, stopErr)
		}
		resource := service.handle
		if service.cmd != nil && service.cmd.Process != nil {
			resource = fmt.Sprintf("%d", service.cmd.Process.Pid)
		}
		_ = recorder.Append(journal.Entry{
			Kind:          "resource_removed",
			ExecutionID:   request.ExecutionID,
			AttemptNumber: request.AttemptNumber,
			ResourceKind:  "service_" + service.kind,
			Resource:      resource,
		})
	}
	if removeErr := os.RemoveAll(session.stateDir); removeErr != nil {
		failures = append(failures, removeErr)
	}
	_ = recorder.Append(journal.Entry{
		Kind:          "resource_removed",
		ExecutionID:   request.ExecutionID,
		AttemptNumber: request.AttemptNumber,
		ResourceKind:  "service_state",
		Resource:      session.stateDir,
	})
	return errors.Join(failures...)
}

func (m *Manager) startOne(
	ctx context.Context,
	request protocol.RequestV1,
	role string,
	root string,
	env map[string]string,
	step serviceplan.Step,
	stateDir string,
) (runningService, error) {
	switch step.Operation {
	case "process.start":
		return startProcess(root, env, step, stateDir)
	case "compose.run":
		if m.Compose == nil {
			return runningService{}, errors.New(
				"compose service provider is unavailable",
			)
		}
		started, err := m.Compose.Start(
			ctx,
			request.ExecutionID,
			role,
			root,
			step.Details,
		)
		if err != nil {
			return runningService{}, err
		}
		name, _ := stringDetail(step.Details, "name")
		urlEnv, _ := stringDetail(step.Details, "url_env")
		scheme, _ := stringDetail(step.Details, "url_scheme")
		return runningService{
			name:   name,
			kind:   "compose",
			handle: started.Handle,
			host:   started.Host,
			port:   started.Port,
			urlEnv: urlEnv,
			url:    fmt.Sprintf("%s://%s:%d", scheme, started.Host, started.Port),
		}, nil
	default:
		return runningService{}, fmt.Errorf(
			"unsupported service start operation %q",
			step.Operation,
		)
	}
}

func startProcess(
	root string,
	env map[string]string,
	step serviceplan.Step,
	stateDir string,
) (runningService, error) {
	name, err := stringDetail(step.Details, "name")
	if err != nil {
		return runningService{}, err
	}
	runtime, err := stringDetail(step.Details, "runtime")
	if err != nil {
		return runningService{}, err
	}
	entrypointValue, err := stringDetail(step.Details, "entrypoint")
	if err != nil {
		return runningService{}, err
	}
	entrypoint, err := resolveInside(root, entrypointValue)
	if err != nil {
		return runningService{}, err
	}
	args, err := stringSliceDetail(step.Details, "args")
	if err != nil {
		return runningService{}, err
	}
	portEnv, err := stringDetail(step.Details, "port_env")
	if err != nil {
		return runningService{}, err
	}
	urlEnv, err := stringDetail(step.Details, "url_env")
	if err != nil {
		return runningService{}, err
	}

	port, err := allocatePort()
	if err != nil {
		return runningService{}, err
	}
	host := "127.0.0.1"
	url := fmt.Sprintf("http://%s:%d", host, port)

	var commandName string
	var commandArgs []string
	switch runtime {
	case "ruby":
		commandName = "ruby"
		commandArgs = append([]string{"--", entrypoint}, args...)
	case "node":
		commandName = "node"
		commandArgs = append([]string{"--", entrypoint}, args...)
	default:
		return runningService{}, fmt.Errorf(
			"unsupported service runtime %q",
			runtime,
		)
	}

	stdoutPath := filepath.Join(stateDir, name+".stdout.log")
	stderrPath := filepath.Join(stateDir, name+".stderr.log")
	stdout, err := os.Create(stdoutPath)
	if err != nil {
		return runningService{}, err
	}
	defer stdout.Close()
	stderr, err := os.Create(stderrPath)
	if err != nil {
		return runningService{}, err
	}
	defer stderr.Close()

	command := exec.Command(commandName, commandArgs...)
	command.Dir = root
	command.Env = safeEnvironment(env)
	command.Env = append(command.Env, portEnv+"="+fmt.Sprintf("%d", port))
	command.Env = append(command.Env, urlEnv+"="+url)
	command.Stdout = stdout
	command.Stderr = stderr
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		return runningService{}, fmt.Errorf(
			"could not start service %q: %w",
			name,
			err,
		)
	}

	return runningService{
		name:       name,
		kind:       "process",
		cmd:        command,
		host:       host,
		port:       port,
		urlEnv:     urlEnv,
		url:        url,
		stderrPath: stderrPath,
	}, nil
}

func (m *Manager) waitHTTP(
	ctx context.Context,
	service runningService,
	step serviceplan.Step,
	env map[string]string,
) error {
	path, err := stringDetail(step.Details, "path")
	if err != nil {
		return err
	}
	timeoutSeconds, err := intDetail(step.Details, "timeout_seconds")
	if err != nil {
		return err
	}
	url := service.url
	if urlEnv, err := stringDetail(step.Details, "url_env"); err == nil {
		if value := env[urlEnv]; value != "" {
			url = value
		}
	}
	target := url + path
	deadline := time.Now().Add(time.Duration(timeoutSeconds) * time.Second)
	client := &http.Client{Timeout: 500 * time.Millisecond}
	var lastError string

	for {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
		if err != nil {
			return err
		}
		response, err := client.Do(request)
		if err == nil {
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
			if response.StatusCode >= 200 && response.StatusCode <= 299 {
				return nil
			}
			lastError = fmt.Sprintf("status=%d", response.StatusCode)
		} else {
			lastError = err.Error()
		}
		if time.Now().After(deadline) {
			return fmt.Errorf(
				"service %q failed readiness at %s: %s; diagnostics=%q",
				service.name,
				target,
				lastError,
				m.diagnostics(ctx, service),
			)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(readinessInterval):
		}
	}
}

func (m *Manager) waitTCP(
	ctx context.Context,
	service runningService,
	step serviceplan.Step,
) error {
	timeoutSeconds, err := intDetail(step.Details, "timeout_seconds")
	if err != nil {
		return err
	}
	deadline := time.Now().Add(time.Duration(timeoutSeconds) * time.Second)
	target := net.JoinHostPort(service.host, fmt.Sprintf("%d", service.port))
	var lastError string

	for {
		connection, err := net.DialTimeout("tcp", target, 500*time.Millisecond)
		if err == nil {
			_ = connection.Close()
			return nil
		}
		lastError = err.Error()
		if time.Now().After(deadline) {
			return fmt.Errorf(
				"service %q failed readiness at tcp://%s: %s; diagnostics=%q",
				service.name,
				target,
				lastError,
				m.diagnostics(ctx, service),
			)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(readinessInterval):
		}
	}
}

func (m *Manager) diagnostics(
	ctx context.Context,
	service runningService,
) string {
	if service.kind == "compose" && m.Compose != nil {
		return m.Compose.Diagnostics(ctx, service.handle)
	}
	body, err := os.ReadFile(service.stderrPath)
	if err != nil {
		return ""
	}
	if len(body) > 2000 {
		body = body[len(body)-2000:]
	}
	return string(body)
}

func stopProcess(ctx context.Context, service runningService) error {
	if service.cmd == nil || service.cmd.Process == nil {
		return nil
	}
	pgid, err := syscall.Getpgid(service.cmd.Process.Pid)
	if err != nil {
		_ = service.cmd.Wait()
		if errors.Is(err, syscall.ESRCH) {
			return nil
		}
		return err
	}
	_ = syscall.Kill(-pgid, syscall.SIGTERM)

	done := make(chan error, 1)
	go func() { done <- service.cmd.Wait() }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		return ctx.Err()
	case <-time.After(stopTimeout):
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		<-done
		return nil
	}
}

func coerceSession(value any) (*Session, error) {
	if value == nil {
		return nil, nil
	}
	session, ok := value.(*Session)
	if !ok {
		return nil, fmt.Errorf("unsupported service session %T", value)
	}
	return session, nil
}

func resolveInside(root string, value string) (string, error) {
	rootResolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	candidate, err := filepath.EvalSymlinks(filepath.Join(rootResolved, value))
	if err != nil {
		return "", err
	}
	prefix := rootResolved + string(os.PathSeparator)
	if !strings.HasPrefix(candidate, prefix) {
		return "", errors.New(
			"service entrypoint must resolve inside repository",
		)
	}
	info, err := os.Stat(candidate)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("service entrypoint must be a regular file")
	}
	return candidate, nil
}

func allocatePort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

func safeEnvironment(explicit map[string]string) []string {
	keys := []string{
		"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
		"SSL_CERT_FILE", "SSL_CERT_DIR",
	}
	environment := make([]string, 0, len(keys)+len(explicit))
	for _, key := range keys {
		if value, ok := os.LookupEnv(key); ok {
			environment = append(environment, key+"="+value)
		}
	}
	explicitKeys := make([]string, 0, len(explicit))
	for key := range explicit {
		explicitKeys = append(explicitKeys, key)
	}
	sort.Strings(explicitKeys)
	for _, key := range explicitKeys {
		environment = append(environment, key+"="+explicit[key])
	}
	return environment
}

func mergeEnv(left map[string]string, right map[string]string) map[string]string {
	result := make(map[string]string, len(left)+len(right))
	for key, value := range left {
		result[key] = value
	}
	for key, value := range right {
		result[key] = value
	}
	return result
}

func stringDetail(details map[string]any, key string) (string, error) {
	value, ok := details[key].(string)
	if !ok || value == "" {
		return "", fmt.Errorf("service detail %q must be a non-empty string", key)
	}
	return value, nil
}

func stringSliceDetail(details map[string]any, key string) ([]string, error) {
	raw, ok := details[key]
	if !ok {
		return []string{}, nil
	}
	values, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("service detail %q must be an array", key)
	}
	result := make([]string, 0, len(values))
	for _, item := range values {
		value, ok := item.(string)
		if !ok {
			return nil, fmt.Errorf(
				"service detail %q must contain strings",
				key,
			)
		}
		result = append(result, value)
	}
	return result, nil
}

func intDetail(details map[string]any, key string) (int, error) {
	value, ok := details[key].(float64)
	if !ok {
		return 0, fmt.Errorf("service detail %q must be an integer", key)
	}
	return int(value), nil
}

func validateStopPlan(session *Session) error {
	planned := map[string]string{}
	for _, step := range session.plan.StepsFor("stop_services") {
		name, err := stringDetail(step.Details, "name")
		if err != nil {
			return err
		}
		if _, exists := planned[name]; exists {
			return fmt.Errorf("duplicate stop plan for service %q", name)
		}
		planned[name] = step.Operation
	}

	running := map[string]string{}
	for _, service := range session.services {
		operation := "process.stop"
		if service.kind == "compose" {
			operation = "compose.stop"
		}
		running[service.name] = operation
	}
	if len(planned) != len(running) {
		return fmt.Errorf(
			"service stop plan does not match running services: planned=%v running=%v",
			planned,
			running,
		)
	}
	for name, operation := range running {
		if planned[name] != operation {
			return fmt.Errorf(
				"service stop plan does not match running services: planned=%v running=%v",
				planned,
				running,
			)
		}
	}
	return nil
}
