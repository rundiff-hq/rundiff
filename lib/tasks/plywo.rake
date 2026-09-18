namespace :plywo do
  desc "Run RunDiff against its own Rails demo execution"
  task dogfood: :environment do
    payload = Plywo::Demo::DogfoodRunner.call
    result = payload.fetch("result")

    puts "RunDiff dogfood run: #{payload.fetch("run_id")}"
    puts "Scenario: #{payload.fetch("scenario_id")}"
    puts
    puts Plywo::ReportRenderer.markdown(result)
    puts
    puts JSON.pretty_generate(payload) if ENV["PLYWO_JSON"] == "1"
    File.write(ENV.fetch("PLYWO_OUTPUT"), JSON.pretty_generate(payload)) if ENV["PLYWO_OUTPUT"]

    abort "RunDiff detected a behavioral regression" if ENV["FAIL_ON_REGRESSION"] == "1" && result.fetch("decision") == "regression"
  end

  desc "Compose two captured executions into one behavioral comparison payload"
  task compare_executions: :environment do
    baseline = Plywo::ExecutionReducer.call(
      execution: JSON.parse(File.read(ENV.fetch("PLYWO_BASELINE_INPUT")))
    )
    candidate = Plywo::ExecutionReducer.call(
      execution: JSON.parse(File.read(ENV.fetch("PLYWO_CANDIDATE_INPUT")))
    )
    changed_paths = if ENV["PLYWO_CHANGED_PATHS"] && File.exist?(ENV["PLYWO_CHANGED_PATHS"])
      File.readlines(ENV.fetch("PLYWO_CHANGED_PATHS"), chomp: true).reject(&:empty?)
    else
      []
    end
    payload = Plywo::ExecutionPair.call(baseline:, candidate:, changed_paths:)

    puts Plywo::ReportRenderer.markdown(payload.fetch("result"))
    puts
    puts JSON.pretty_generate(payload)
    File.write(ENV.fetch("PLYWO_OUTPUT"), JSON.pretty_generate(payload)) if ENV["PLYWO_OUTPUT"]
  end

  desc "Render and optionally publish the durable RunDiff GitHub PR comment"
  task github_comment: :environment do
    payload = JSON.parse(File.read(ENV.fetch("PLYWO_INPUT")))
    event = if ENV["GITHUB_EVENT_PATH"] && File.exist?(ENV["GITHUB_EVENT_PATH"])
      JSON.parse(File.read(ENV["GITHUB_EVENT_PATH"]))
    else
      {}
    end

    pr_number = ENV["PLYWO_PR_NUMBER"] || event["number"] || event.dig("pull_request", "number")
    context = {
      repository: ENV["GITHUB_REPOSITORY"],
      pr_number:,
      baseline_label: ENV["PLYWO_BASELINE_LABEL"] || event.dig("pull_request", "base", "ref"),
      baseline_sha: ENV["PLYWO_BASELINE_SHA"] || event.dig("pull_request", "base", "sha"),
      candidate_label: ENV["PLYWO_CANDIDATE_LABEL"] || event.dig("pull_request", "head", "ref"),
      candidate_sha: ENV["PLYWO_CANDIDATE_SHA"] || event.dig("pull_request", "head", "sha"),
      bootstrap_baseline: ENV["PLYWO_BOOTSTRAP_BASELINE"],
      execution_mode: ENV["PLYWO_EXECUTION_MODE"],
      run_url: ENV["PLYWO_RUN_URL"]
    }
    markdown = Plywo::Github::CommentRenderer.markdown(payload:, context:)

    puts markdown
    File.write(ENV.fetch("PLYWO_COMMENT_OUTPUT"), markdown) if ENV["PLYWO_COMMENT_OUTPUT"]

    next unless ENV["PLYWO_PUBLISH"] == "1"

    publisher = Plywo::Github::CommentPublisher.new(
      token: ENV.fetch("GITHUB_TOKEN"),
      api_url: ENV.fetch("GITHUB_API_URL", "https://api.github.com")
    )
    action = publisher.upsert(
      repository: ENV.fetch("GITHUB_REPOSITORY"),
      pr_number: Integer(pr_number),
      body: markdown,
      author: ENV["PLYWO_COMMENT_AUTHOR"],
      expected_head_sha: context.fetch(:candidate_sha)
    )
    puts "RunDiff GitHub comment #{action}."
  end

  desc "Publish the RunDiff behavioral decision as a GitHub Check Run"
  task github_check: :environment do
    payload = JSON.parse(File.read(ENV.fetch("PLYWO_INPUT")))
    rendered = Plywo::Github::CheckRenderer.call(payload:, run_url: ENV["PLYWO_RUN_URL"])

    puts "#{rendered.fetch("name")}: #{rendered.fetch("conclusion")} - #{rendered.fetch("title")}"
    puts rendered.fetch("summary")

    next unless ENV["PLYWO_PUBLISH"] == "1"

    publisher = Plywo::Github::CheckPublisher.new(
      token: ENV.fetch("GITHUB_TOKEN"),
      api_url: ENV.fetch("GITHUB_API_URL", "https://api.github.com")
    )
    action = publisher.upsert(
      repository: ENV.fetch("GITHUB_REPOSITORY"),
      head_sha: ENV.fetch("PLYWO_CANDIDATE_SHA"),
      name: rendered.fetch("name"),
      external_id: payload.fetch("run_id"),
      details_url: ENV.fetch("PLYWO_RUN_URL"),
      conclusion: rendered.fetch("conclusion"),
      title: rendered.fetch("title"),
      summary: rendered.fetch("summary"),
      annotations: rendered.fetch("annotations")
    )
    puts "RunDiff GitHub check #{action}."
  end
end
