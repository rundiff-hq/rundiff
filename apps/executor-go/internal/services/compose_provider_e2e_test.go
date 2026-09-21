package services

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/serviceplan"
)

func TestIsolatedComposeProviderEndToEnd(t *testing.T) {
	if os.Getenv("RUNDIFF_GO_COMPOSE_E2E") != "1" {
		t.Skip("set RUNDIFF_GO_COMPOSE_E2E=1 to run isolated Compose E2E")
	}
	if _, err := os.Stat("/var/run/docker.sock"); err == nil {
		t.Fatal("executor proof must not receive Docker socket")
	}

	provider := ComposeProviderFromEnv()
	if provider == nil {
		t.Fatal("RUNDIFF_COMPOSE_PROVIDER_SOCKET is required")
	}

	root := t.TempDir()
	if err := os.WriteFile(
		filepath.Join(root, "compose.yml"),
		[]byte("services:\n  redis:\n    image: redis:7-alpine\n"),
		0o600,
	); err != nil {
		t.Fatalf("write compose manifest: %v", err)
	}

	plan := serviceplan.Plan{
		SchemaVersion: serviceplan.SchemaVersion,
		Steps: []serviceplan.Step{
			{
				Phase:     "start_services",
				Operation: "compose.run",
				Details: map[string]any{
					"name":        "cache",
					"manifest":    "compose.yml",
					"service":     "redis",
					"target_port": float64(6379),
					"url_scheme":  "redis",
					"url_env":     "REDIS_URL",
				},
			},
			{
				Phase:     "healthcheck",
				Operation: "tcp.wait_ready",
				Details: map[string]any{
					"name":            "cache",
					"url_env":         "REDIS_URL",
					"timeout_seconds": float64(10),
				},
			},
			{
				Phase:     "stop_services",
				Operation: "compose.stop",
				Details:   map[string]any{"name": "cache"},
			},
		},
	}
	manager := NewManager(
		staticCompiler{plan: plan},
		provider,
	)
	request := protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID:   "go-compose-e2e",
		ScenarioID:    "compose.redis",
		BaselineSHA:   "aaa",
		CandidateSHA:  "bbb",
		AttemptNumber: 1,
		Context: protocol.ContextV1{
			Repository: "rundiff-hq/rundiff",
		},
	}
	recorder := &memoryRecorder{}

	sessionValue, serviceEnv, err := manager.Start(
		context.Background(),
		request,
		"candidate",
		root,
		map[string]string{},
		recorder,
	)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	stopped := false
	defer func() {
		if stopped {
			return
		}
		_ = manager.Stop(
			context.Background(),
			request,
			"candidate",
			root,
			serviceEnv,
			sessionValue,
			recorder,
		)
	}()

	if err := manager.Ready(
		context.Background(),
		request,
		"candidate",
		root,
		serviceEnv,
		sessionValue,
	); err != nil {
		t.Fatalf("Ready: %v", err)
	}

	session := sessionValue.(*Session)
	service := session.services[0]
	connection, err := net.DialTimeout(
		"tcp",
		net.JoinHostPort(service.host, fmt.Sprintf("%d", service.port)),
		time.Second,
	)
	if err != nil {
		t.Fatalf("connect Redis: %v", err)
	}
	if _, err := connection.Write([]byte("*1\r\n$4\r\nPING\r\n")); err != nil {
		connection.Close()
		t.Fatalf("write Redis PING: %v", err)
	}
	response, err := bufio.NewReader(connection).ReadString('\n')
	connection.Close()
	if err != nil {
		t.Fatalf("read Redis PONG: %v", err)
	}
	if response != "+PONG\r\n" {
		t.Fatalf("unexpected Redis response: %q", response)
	}

	if err := manager.Stop(
		context.Background(),
		request,
		"candidate",
		root,
		serviceEnv,
		sessionValue,
		recorder,
	); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	stopped = true

	target := net.JoinHostPort(service.host, fmt.Sprintf("%d", service.port))
	deadline := time.Now().Add(3 * time.Second)
	for {
		connection, err := net.DialTimeout("tcp", target, 100*time.Millisecond)
		if err != nil {
			break
		}
		connection.Close()
		if time.Now().After(deadline) {
			t.Fatalf("Compose endpoint remained reachable after teardown: %s", target)
		}
		time.Sleep(50 * time.Millisecond)
	}

	var created bool
	var removed bool
	for _, entry := range recorder.entries {
		if entry.ResourceKind != "service_compose" {
			continue
		}
		if entry.Kind == "resource_created" {
			created = true
		}
		if entry.Kind == "resource_removed" {
			removed = true
		}
	}
	if !created || !removed {
		t.Fatalf("missing Compose resource journal entries: %+v", recorder.entries)
	}

	t.Logf("go_compose_provider_e2e=passed")
	t.Logf("redis_ping=PONG")
	t.Logf("endpoint_cleanup=true")
}
