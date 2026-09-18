require "test_helper"
require "tmpdir"

class PlywoSubjectConfigurationTest < ActiveSupport::TestCase
  test "missing config keeps automatic persistence and setup defaults" do
    Dir.mktmpdir do |directory|
      configuration = Plywo::Subject::Configuration.load(root: directory)

      assert_equal "auto", configuration.persistence
      assert_equal "auto", configuration.setup_mode
      assert_empty configuration.services
      assert_nil configuration.scenario_path
      assert_equal({}, configuration.capture_env)
      assert_nil configuration.source_path
    end
  end

  test "loads candidate scenario, persistence, and setup mode" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "rundiff.yml"), <<~YAML)
        version: 1
        scenario:
          path: /orders/42
        subject:
          persistence: sqlite
          setup:
            mode: auto
      YAML

      configuration = Plywo::Subject::Configuration.load(root: directory)

      assert_equal "sqlite", configuration.persistence
      assert_equal "auto", configuration.setup_mode
      assert_empty configuration.services
      assert_equal "/orders/42", configuration.scenario_path
      assert_equal({ "PLYWO_SCENARIO_PATH" => "/orders/42" }, configuration.capture_env)
      assert_equal Pathname(directory).join("rundiff.yml"), configuration.source_path
    end
  end

  test "falls back to legacy plywo.yml when rundiff.yml is absent" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "plywo.yml"), <<~YAML)
        version: 1
        scenario:
          path: /legacy
      YAML

      configuration = Plywo::Subject::Configuration.load(root: directory)

      assert_equal "/legacy", configuration.scenario_path
      assert_equal Pathname(directory).join("plywo.yml"), configuration.source_path
    end
  end

  test "prefers rundiff.yml over legacy plywo.yml" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "plywo.yml"), "version: 1\nscenario:\n  path: /legacy\n")
      File.write(File.join(directory, "rundiff.yml"), "version: 1\nscenario:\n  path: /canonical\n")

      configuration = Plywo::Subject::Configuration.load(root: directory)

      assert_equal "/canonical", configuration.scenario_path
      assert_equal Pathname(directory).join("rundiff.yml"), configuration.source_path
    end
  end

  test "loads explicit Ruby process service with bounded HTTP readiness" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "plywo.yml"), <<~YAML)
        version: 1
        subject:
          services:
            - name: mock-api
              type: process
              runtime: ruby
              entrypoint: script/mock_api.rb
              args: [ready]
              port_env: MOCK_API_PORT
              url_env: MOCK_API_URL
              readiness:
                type: http
                path: /health
                timeout_seconds: 3
      YAML

      configuration = Plywo::Subject::Configuration.load(root: directory)
      service = configuration.services.fetch(0)

      assert_instance_of Plywo::Subject::Configuration::ProcessService, service
      assert_equal "mock-api", service.name
      assert_equal "process", service.type
      assert_equal "ruby", service.runtime
      assert_equal "script/mock_api.rb", service.entrypoint
      assert_equal [ "ready" ], service.args
      assert_equal "MOCK_API_PORT", service.port_env
      assert_equal "MOCK_API_URL", service.url_env
      assert_equal "http", service.readiness.type
      assert_equal "/health", service.readiness.path
      assert_equal 3, service.readiness.timeout_seconds
    end
  end

  test "loads explicit Compose service with TCP readiness" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "plywo.yml"), <<~YAML)
        version: 1
        subject:
          services:
            - name: cache
              type: compose
              manifest: docker/compose.yml
              service: redis
              target_port: 6379
              url_scheme: redis
              url_env: REDIS_URL
              readiness:
                type: tcp
                timeout_seconds: 8
      YAML

      configuration = Plywo::Subject::Configuration.load(root: directory)
      service = configuration.services.fetch(0)

      assert_instance_of Plywo::Subject::Configuration::ComposeService, service
      assert_equal "cache", service.name
      assert_equal "compose", service.type
      assert_equal "docker/compose.yml", service.manifest
      assert_equal "redis", service.service
      assert_equal 6379, service.target_port
      assert_equal "redis", service.url_scheme
      assert_equal "REDIS_URL", service.url_env
      assert_equal "tcp", service.readiness.type
      assert_nil service.readiness.path
      assert_equal 8, service.readiness.timeout_seconds
    end
  end

  test "rejects unknown versions and persistence values" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "plywo.yml")
      File.write(path, "version: 2\n")

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/Unsupported plywo.yml version/, error.message)

      File.write(path, "version: 1\nsubject:\n  persistence: mysql\n")
      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/Unsupported subject.persistence/, error.message)
    end
  end

  test "rejects unsupported setup modes" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "plywo.yml"), <<~YAML)
        version: 1
        subject:
          setup:
            mode: shell
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end

      assert_match(/Unsupported subject.setup.mode/, error.message)
    end
  end

  test "rejects arbitrary command fields and unsupported service runtimes" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "plywo.yml")
      File.write(path, <<~YAML)
        version: 1
        subject:
          services:
            - name: mock-api
              type: process
              runtime: ruby
              entrypoint: script/mock_api.rb
              command: [sh, -c, anything]
              url_env: MOCK_API_URL
              readiness:
                type: http
                path: /health
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/Unknown subject.services\[0\] keys: command/, error.message)

      File.write(path, <<~YAML)
        version: 1
        subject:
          services:
            - name: mock-api
              type: process
              runtime: shell
              entrypoint: script/mock_api.rb
              url_env: MOCK_API_URL
              readiness:
                type: http
                path: /health
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/Unsupported subject.services\[0\].runtime/, error.message)
    end
  end

  test "rejects entrypoint traversal and malformed args" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "plywo.yml")
      File.write(path, <<~YAML)
        version: 1
        subject:
          services:
            - name: mock-api
              type: process
              runtime: ruby
              entrypoint: ../outside.rb
              url_env: MOCK_API_URL
              readiness:
                type: http
                path: /health
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/entrypoint must be a repository-relative path without/, error.message)

      File.write(path, <<~YAML)
        version: 1
        subject:
          services:
            - name: mock-api
              type: process
              runtime: ruby
              entrypoint: service.rb
              args: ready
              url_env: MOCK_API_URL
              readiness:
                type: http
                path: /health
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/args must be a sequence of strings/, error.message)
    end
  end

  test "rejects unsafe Compose paths and malformed endpoint fields" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "plywo.yml")
      File.write(path, <<~YAML)
        version: 1
        subject:
          services:
            - name: cache
              type: compose
              manifest: ../compose.yml
              service: redis
              target_port: 6379
              url_scheme: redis
              url_env: REDIS_URL
              readiness:
                type: tcp
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/manifest must be a repository-relative path without/, error.message)

      File.write(path, <<~YAML)
        version: 1
        subject:
          services:
            - name: cache
              type: compose
              manifest: compose.yml
              service: redis
              target_port: 70000
              url_scheme: redis
              url_env: REDIS_URL
              readiness:
                type: tcp
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/target_port must be an integer between 1 and 65535/, error.message)
    end
  end

  test "rejects readiness path for TCP services" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "plywo.yml"), <<~YAML)
        version: 1
        subject:
          services:
            - name: cache
              type: compose
              manifest: compose.yml
              service: redis
              target_port: 6379
              url_scheme: redis
              url_env: REDIS_URL
              readiness:
                type: tcp
                path: /health
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end

      assert_match(/path is only valid for HTTP readiness/, error.message)
    end
  end

  test "rejects duplicate service names and URL exports" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "plywo.yml")
      File.write(path, <<~YAML)
        version: 1
        subject:
          services:
            - name: mock-api
              type: process
              runtime: ruby
              entrypoint: one.rb
              url_env: MOCK_API_URL
              readiness:
                type: http
                path: /health
            - name: mock-api
              type: process
              runtime: ruby
              entrypoint: two.rb
              url_env: OTHER_API_URL
              readiness:
                type: http
                path: /health
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/Duplicate subject.services names: mock-api/, error.message)

      File.write(path, <<~YAML)
        version: 1
        subject:
          services:
            - name: first-api
              type: process
              runtime: ruby
              entrypoint: one.rb
              url_env: SHARED_API_URL
              readiness:
                type: http
                path: /health
            - name: second-api
              type: process
              runtime: ruby
              entrypoint: two.rb
              url_env: SHARED_API_URL
              readiness:
                type: http
                path: /health
      YAML

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end
      assert_match(/Duplicate subject.services url_env values: SHARED_API_URL/, error.message)
    end
  end

  test "rejects unsafe or malformed scenario paths" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "plywo.yml"), "version: 1\nscenario:\n  path: orders/42\n")

      error = assert_raises(Plywo::Subject::Configuration::Error) do
        Plywo::Subject::Configuration.load(root: directory)
      end

      assert_match(/scenario.path must be an absolute HTTP path/, error.message)
    end
  end
end
