#!/usr/bin/env ruby

require "base64"
require "json"
require "net/http"
require "openssl"
require "open3"
require "securerandom"
require "time"
require "uri"

module RunDiffProductionLab
  EMULATOR_URL = ENV.fetch("GITHUB_EMULATOR_URL", "http://github-emulator:4001")
  CONTROL_PLANE_URL = ENV.fetch("RUNDIFF_LAB_CONTROL_PLANE_URL", "https://control-plane-tls:4444")
  EXECUTOR_URL = ENV.fetch("RUNDIFF_LAB_EXECUTOR_URL", "https://executor-tls:4443")
  ADMIN_TOKEN = ENV.fetch("RUNDIFF_LAB_GITHUB_ADMIN_TOKEN", "lab-admin-token")
  CHECK_NAME = ENV.fetch("RUNDIFF_GITHUB_APP_CHECK_NAME", "RunDiff Lab / Behavioral Diff")
  CUSTOMER_REPOSITORY = "admin/customer-rails"
  DISALLOWED_REPOSITORY = "admin/not-allowed"
  TIMEOUT_SECONDS = Integer(ENV.fetch("RUNDIFF_LAB_TIMEOUT_SECONDS", "300"))

  module_function

  def call
    started_at = monotonic_now
    wait_until_ready!("#{EMULATOR_URL}/meta")
    wait_until_ready!("#{CONTROL_PLANE_URL}/ready")
    wait_until_ready!("#{EXECUTOR_URL}/ready")

    regression = create_pull_request!(
      repository: CUSTOMER_REPOSITORY,
      branch: "regression",
      title: "Production lab SQL regression"
    )
    raise "Expected regression PR #1, got ##{regression.fetch("number")}" unless regression.fetch("number") == 1
    assert_behavioral_review!(pull_request: regression, expected_conclusion: "failure", expected_text: "DATABASE_QUERY_REGRESSION")
    assert_operator_replay!(pull_request: regression, expected_text: "DATABASE_QUERY_REGRESSION")

    neutral = create_pull_request!(
      repository: CUSTOMER_REPOSITORY,
      branch: "neutral",
      title: "Production lab neutral candidate"
    )
    raise "Expected neutral PR #2, got ##{neutral.fetch("number")}" unless neutral.fetch("number") == 2
    assert_behavioral_review!(pull_request: neutral, expected_conclusion: "success", expected_text: "ALLOW")

    assert_invalid_webhook_signature!
    assert_disallowed_repository_is_ignored!
    assert_wrong_executor_token_is_rejected!

    puts "production_lab=ok"
    puts "production_lab_regression=BLOCK:DATABASE_QUERY_REGRESSION"
    puts "production_lab_neutral=ALLOW"
    puts "production_lab_operator_replay=verified"
    puts "production_lab_invalid_webhook_signature=rejected"
    puts "production_lab_disallowed_repository=ignored"
    puts "production_lab_wrong_executor_token=rejected"
    puts "production_lab_elapsed_ms=#{elapsed_ms(started_at)}"
  end

  def create_pull_request!(repository:, branch:, title:)
    base = github_json(:get, "/repos/#{repository}/git/ref/heads/main")
    base_sha = base.dig("object", "sha") || raise("Missing main SHA for #{repository}")

    github_json(
      :post,
      "/repos/#{repository}/git/refs",
      body: { ref: "refs/heads/#{branch}", sha: base_sha }
    )

    github_json(
      :put,
      "/repos/#{repository}/contents/#{branch}.txt",
      body: {
        message: "Create #{branch} candidate",
        content: Base64.strict_encode64("#{branch}\n"),
        branch:
      }
    )

    github_json(
      :post,
      "/repos/#{repository}/pulls",
      body: {
        title:,
        head: branch,
        base: "main",
        body: "Created by the hermetic RunDiff production lab."
      }
    )
  end

  def assert_behavioral_review!(pull_request:, expected_conclusion:, expected_text:)
    started_at = monotonic_now
    repository = pull_request.dig("base", "repo", "full_name") || CUSTOMER_REPOSITORY
    number = pull_request.fetch("number")
    emulator_head_sha = pull_request.dig("head", "sha") || raise("Missing emulator head SHA")

    check_run = wait_for("Check Run for #{repository}##{number}") do
      response = github_json(
        :get,
        "/repos/#{repository}/commits/#{emulator_head_sha}/check-runs?check_name=#{URI.encode_www_form_component(CHECK_NAME)}"
      )
      response.fetch("check_runs", []).find do |check|
        check["name"] == CHECK_NAME && check["status"] == "completed"
      end
    end

    unless check_run.fetch("conclusion") == expected_conclusion
      raise "Expected #{repository}##{number} conclusion #{expected_conclusion.inspect}, got #{check_run.fetch("conclusion").inspect}: #{check_run.inspect}"
    end

    check_text = [
      check_run.dig("output", "title"),
      check_run.dig("output", "summary"),
      check_run.dig("output", "text")
    ].compact.join("\n")
    unless check_text.include?(expected_text)
      raise "Expected #{repository}##{number} Check Run to contain #{expected_text.inspect}: #{check_text}"
    end

    comment = wait_for("RunDiff comment for #{repository}##{number}") do
      github_json(:get, "/repos/#{repository}/issues/#{number}/comments").find do |item|
        item.fetch("body", "").include?("<!-- rundiff:behavioral-diff:v1 -->")
      end
    end

    unless comment.fetch("body").include?(expected_text)
      raise "Expected #{repository}##{number} comment to contain #{expected_text.inspect}: #{comment.fetch("body")}"
    end

    puts "production_lab_pr=#{number} conclusion=#{check_run.fetch("conclusion")} expected=#{expected_text} elapsed_ms=#{elapsed_ms(started_at)}"
  rescue StandardError
    warn "production_lab_pr=#{number || "unknown"} status=error elapsed_ms=#{elapsed_ms(started_at)}"
    raise
  end

  def assert_operator_replay!(pull_request:, expected_text:)
    started_at = monotonic_now
    number = pull_request.fetch("number")
    root = File.expand_path("..", __dir__)
    command = [
      File.join(root, "bin", "replay-github-pr"),
      CUSTOMER_REPOSITORY,
      number.to_s,
      "--wait",
      "60",
      "--color",
      "never"
    ]

    stdout, stderr, status = Open3.capture3(*command, chdir: root)
    unless status.success?
      raise "Operator PR replay failed for #{CUSTOMER_REPOSITORY}##{number}: #{stderr.presence || stdout}"
    end

    unless stdout.include?("review_delivery=accepted")
      raise "Operator PR replay did not accept a signed delivery: #{stdout}"
    end
    unless stdout.include?("execution_status=completed")
      raise "Operator PR replay did not resolve the durable execution: #{stdout}"
    end
    unless stdout.include?(expected_text)
      raise "Operator PR replay did not render #{expected_text.inspect}: #{stdout}"
    end

    puts "production_lab_operator_replay=verified pr=#{number} elapsed_ms=#{elapsed_ms(started_at)}"
  rescue StandardError
    warn "production_lab_operator_replay=error pr=#{number || "unknown"} elapsed_ms=#{elapsed_ms(started_at)}"
    raise
  end

  def assert_invalid_webhook_signature!
    body = JSON.generate({ action: "opened" })
    response = raw_request(
      :post,
      "#{CONTROL_PLANE_URL}/github/webhooks",
      headers: {
        "Content-Type" => "application/json",
        "X-GitHub-Event" => "pull_request",
        "X-GitHub-Delivery" => "invalid-signature-#{SecureRandom.hex(8)}",
        "X-Hub-Signature-256" => "sha256=#{"0" * 64}"
      },
      body:
    )
    raise "Invalid webhook signature was not rejected: HTTP #{response.code}" unless response.code.to_i == 401
  end

  def assert_disallowed_repository_is_ignored!
    pull_request = create_pull_request!(
      repository: DISALLOWED_REPOSITORY,
      branch: "candidate",
      title: "Production lab repository admission negative case"
    )
    emulator_head_sha = pull_request.dig("head", "sha") || raise("Missing disallowed repo head SHA")

    sleep 2
    checks = github_json(:get, "/repos/#{DISALLOWED_REPOSITORY}/commits/#{emulator_head_sha}/check-runs")
    comments = github_json(:get, "/repos/#{DISALLOWED_REPOSITORY}/issues/#{pull_request.fetch("number")}/comments")

    raise "Disallowed repository unexpectedly received a RunDiff Check Run" unless checks.fetch("check_runs", []).empty?
    raise "Disallowed repository unexpectedly received a RunDiff comment" if comments.any? { |item| item.fetch("body", "").include?("rundiff:behavioral-diff") }
  end

  def assert_wrong_executor_token_is_rejected!
    response = raw_request(
      :post,
      "#{EXECUTOR_URL}/v1/executions",
      headers: {
        "Authorization" => "Bearer definitely-wrong-token",
        "Content-Type" => "application/json",
        "Idempotency-Key" => "negative-#{SecureRandom.hex(8)}"
      },
      body: JSON.generate({})
    )
    raise "Wrong executor token was not rejected: HTTP #{response.code}" unless response.code.to_i == 401
  end

  def wait_until_ready!(url)
    wait_for("readiness #{url}") do
      response = raw_request(:get, url)
      response.code.to_i.between?(200, 299) ? response : nil
    rescue StandardError
      nil
    end
  end

  def wait_for(description)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT_SECONDS
    loop do
      result = yield
      return result if result
      raise "Timed out waiting for #{description}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 1
    end
  end

  def github_json(method, path, body: nil)
    response = raw_request(
      method,
      "#{EMULATOR_URL}#{path}",
      headers: {
        "Authorization" => "Bearer #{ADMIN_TOKEN}",
        "Accept" => "application/vnd.github+json",
        "Content-Type" => "application/json"
      },
      body: body && JSON.generate(body)
    )
    unless response.code.to_i.between?(200, 299)
      raise "GitHub emulator request failed #{method.to_s.upcase} #{path}: HTTP #{response.code} #{response.body}"
    end
    response.body.to_s.empty? ? nil : JSON.parse(response.body)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_now - started_at) * 1_000).round
  end

  def raw_request(method, url, headers: {}, body: nil)
    uri = URI(url)
    request_class = {
      get: Net::HTTP::Get,
      post: Net::HTTP::Post,
      put: Net::HTTP::Put,
      patch: Net::HTTP::Patch,
      delete: Net::HTTP::Delete
    }.fetch(method)
    request = request_class.new(uri)
    headers.each { |name, value| request[name] = value }
    request.body = body if body

    http = Net::HTTP.new(uri.host, uri.port)
    if uri.scheme == "https"
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.ca_file = ENV["SSL_CERT_FILE"] if ENV["SSL_CERT_FILE"]
    end
    http.open_timeout = 5
    http.read_timeout = 30
    http.request(request)
  end
end

RunDiffProductionLab.call
