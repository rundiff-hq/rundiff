package services

import (
	"context"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/journal"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/protocol"
	"github.com/rundiff-hq/rundiff/apps/executor-go/internal/serviceplan"
)

type staticCompiler struct {
	plan serviceplan.Plan
}

func (c staticCompiler) Compile(
	context.Context,
	string,
) (serviceplan.Plan, error) {
	return c.plan, nil
}

type memoryRecorder struct {
	entries []journal.Entry
}

func (r *memoryRecorder) Append(entry journal.Entry) error {
	r.entries = append(r.entries, entry)
	return nil
}

func TestManagerStartsReadiesAndStopsRubyProcess(t *testing.T) {
	if _, err := exec.LookPath("ruby"); err != nil {
		t.Skip("ruby is not available")
	}

	root := t.TempDir()
	service := filepath.Join(root, "service.rb")
	body := `require "socket"
server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT"), 10))
trap("TERM") { server.close rescue nil; exit! 0 }
loop do
  client = server.accept
  while (line = client.gets)
    break if line == "\r\n"
  end
  response = "OK"
  client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
  client.close
end
`
	if err := os.WriteFile(service, []byte(body), 0o600); err != nil {
		t.Fatalf("write service: %v", err)
	}

	plan := serviceplan.Plan{
		SchemaVersion: serviceplan.SchemaVersion,
		Steps: []serviceplan.Step{
			{
				Phase: "start_services",
				Operation: "process.start",
				Details: map[string]any{
					"name": "mock-api",
					"runtime": "ruby",
					"entrypoint": "service.rb",
					"args": []any{},
					"port_env": "PORT",
					"url_env": "MOCK_API_URL",
				},
			},
			{
				Phase: "healthcheck",
				Operation: "http.wait_ready",
				Details: map[string]any{
					"name": "mock-api",
					"url_env": "MOCK_API_URL",
					"path": "/health",
					"timeout_seconds": float64(2),
				},
			},
			{
				Phase: "stop_services",
				Operation: "process.stop",
				Details: map[string]any{"name": "mock-api"},
			},
		},
	}
	recorder := &memoryRecorder{}
	manager := NewManager(staticCompiler{plan: plan}, nil)
	request := protocol.RequestV1{
		SchemaVersion: protocol.SchemaVersion,
		ExecutionID: "service-proof",
		ScenarioID: "scenario",
		BaselineSHA: "aaa",
		CandidateSHA: "bbb",
		AttemptNumber: 1,
		Context: protocol.ContextV1{
			Repository: "demo/repo",
		},
	}

	session, serviceEnv, err := manager.Start(
		context.Background(),
		request,
		"base",
		root,
		map[string]string{},
		recorder,
	)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := manager.Ready(
		context.Background(),
		request,
		"base",
		root,
		serviceEnv,
		session,
	); err != nil {
		t.Fatalf("Ready: %v", err)
	}
	response, err := http.Get(serviceEnv["MOCK_API_URL"] + "/health")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", response.StatusCode)
	}
	if err := manager.Stop(
		context.Background(),
		request,
		"base",
		root,
		serviceEnv,
		session,
		recorder,
	); err != nil {
		t.Fatalf("Stop: %v", err)
	}
}
