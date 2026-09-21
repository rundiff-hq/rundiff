package serviceplan

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestNativeCompilerMatchesRubyServicePlanOracle(t *testing.T) {
	toolRoot, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatalf("tool root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(toolRoot, "script", "compile_service_plan.rb")); err != nil {
		t.Skip("Ruby service-plan oracle unavailable")
	}

	root := t.TempDir()
	writeConfig(t, root, `version: 1
subject:
  services:
    - name: mock-api
      type: process
      runtime: ruby
      entrypoint: script/mock_api.rb
      args: ["--quiet"]
      port_env: PORT
      url_env: MOCK_API_URL
      readiness:
        type: http
        path: /health
        timeout_seconds: 7
    - name: cache
      type: compose
      manifest: compose.yml
      service: redis
      target_port: 6379
      url_scheme: redis
      url_env: REDIS_URL
      readiness:
        type: tcp
        timeout_seconds: 9
`)
	// The Ruby oracle also requires a recognizable Rails subject.
	if err := os.WriteFile(
		filepath.Join(root, "Gemfile"),
		[]byte("gem \"rails\"\n"),
		0o600,
	); err != nil {
		t.Fatalf("Gemfile: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o700); err != nil {
		t.Fatalf("mkdir bin: %v", err)
	}
	if err := os.WriteFile(
		filepath.Join(root, "bin", "rails"),
		[]byte("#!/usr/bin/env ruby\n"),
		0o700,
	); err != nil {
		t.Fatalf("bin/rails: %v", err)
	}
	if err := os.WriteFile(
		filepath.Join(root, "Gemfile.lock"),
		[]byte("GEM\n  specs:\n    rails (8.0.0)\n\nBUNDLED WITH\n   2.6.0\n"),
		0o600,
	); err != nil {
		t.Fatalf("Gemfile.lock: %v", err)
	}

	ctx := context.Background()
	native, err := NewNativeCompiler().Compile(ctx, root)
	if err != nil {
		t.Fatalf("native Compile: %v", err)
	}
	ruby, err := NewRubyCompiler(toolRoot).Compile(ctx, root)
	if err != nil {
		t.Fatalf("Ruby Compile: %v", err)
	}
	if !reflect.DeepEqual(native, ruby) {
		t.Fatalf("native/Ruby plan mismatch\nnative=%#v\nruby=%#v", native, ruby)
	}
}
