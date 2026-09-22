package services

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestIsolatedComposeProviderUsesProtocolV1(t *testing.T) {
	root := t.TempDir()
	manifest := filepath.Join(root, "compose.yml")
	if err := os.WriteFile(
		manifest,
		[]byte("services:\n  api:\n    image: nginx:alpine\n"),
		0o600,
	); err != nil {
		t.Fatalf("write manifest: %v", err)
	}

	socketPath := filepath.Join(t.TempDir(), "provider.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer listener.Close()

	done := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer connection.Close()

		raw, err := bufio.NewReader(connection).ReadBytes('\n')
		if err != nil {
			done <- err
			return
		}
		var request map[string]any
		if err := json.Unmarshal(raw, &request); err != nil {
			done <- err
			return
		}
		requestID := request["request_id"].(string)
		payload := request["payload"].(map[string]any)
		if payload["manifest"] == "" {
			done <- os.ErrInvalid
			return
		}
		response, _ := json.Marshal(map[string]any{
			"request_id": requestID,
			"ok":         true,
			"payload": map[string]any{
				"handle_id": "handle-1",
				"host":      "127.0.0.1",
				"port":      43210,
			},
		})
		_, err = connection.Write(append(response, '\n'))
		done <- err
	}()

	provider := &IsolatedComposeProvider{SocketPath: socketPath}
	started, err := provider.Start(
		context.Background(),
		"execution-1",
		"base",
		root,
		map[string]any{
			"name":        "api",
			"manifest":    "compose.yml",
			"service":     "api",
			"target_port": float64(80),
			"url_scheme":  "http",
			"url_env":     "API_URL",
		},
	)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if started.Handle != "handle-1" ||
		started.Host != "127.0.0.1" ||
		started.Port != 43210 {
		t.Fatalf("unexpected started service: %+v", started)
	}
	if err := <-done; err != nil {
		t.Fatalf("server: %v", err)
	}
}
