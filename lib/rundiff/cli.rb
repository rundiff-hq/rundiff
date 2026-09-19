require "json"
require "optparse"
require_relative "behavioral_diff"
require_relative "report_renderer"
require_relative "terminal_renderer"
require_relative "github/comment_renderer"
require_relative "demo/customer_review_runner"

module RunDiff
  class CLI
    def initialize(argv, stdout: $stdout, stderr: $stderr, demo_runner: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @demo_runner = demo_runner || Demo::CustomerReviewRunner.new(stderr:)
    end

    def run
      case (command = @argv.shift)
      when "diff"
        run_diff
      when "review"
        run_review
      when "demo"
        run_demo
      when "version", "--version", "-v"
        @stdout.puts "rundiff 0.0.1"
        0
      else
        @stderr.puts usage
        command.nil? ? 0 : 2
      end
    rescue OptionParser::ParseError, KeyError, JSON::ParserError, Errno::ENOENT, ArgumentError,
      Demo::CustomerReviewRunner::Error => error
      @stderr.puts "rundiff: #{error.message}"
      2
    end

    private

    def run_diff
      options = { format: "markdown", fail_on_regression: false }

      OptionParser.new do |opts|
        opts.on("--baseline FILE") { |value| options[:baseline] = value }
        opts.on("--candidate FILE") { |value| options[:candidate] = value }
        opts.on("--format FORMAT", %w[markdown json]) { |value| options[:format] = value }
        opts.on("--fail-on-regression") { options[:fail_on_regression] = true }
      end.parse!(@argv)

      result = BehavioralDiff.call(
        baseline: read_measurements(options.fetch(:baseline)),
        candidate: read_measurements(options.fetch(:candidate))
      )

      @stdout.puts(options[:format] == "json" ? JSON.pretty_generate(result) : ReportRenderer.markdown(result))
      options[:fail_on_regression] && result.fetch("decision") == "regression" ? 1 : 0
    end

    def run_review
      options = review_options(require_input: true)
      payload = read_review_payload(options.fetch(:input))
      publish_review(payload:, options:)
    end

    def run_demo
      options = review_options(require_input: false, allow_output: true)
      payload = @demo_runner.call(output_path: options[:output])
      publish_review(payload:, options:)
    end

    def review_options(require_input:, allow_output: false)
      options = { format: "terminal", color: "auto", fail_on_block: false }

      OptionParser.new do |opts|
        opts.on("--input FILE") { |value| options[:input] = value } if require_input
        opts.on("--output FILE") { |value| options[:output] = value } if allow_output
        opts.on("--format FORMAT", %w[terminal markdown json]) { |value| options[:format] = value }
        opts.on("--color WHEN", %w[auto always never]) { |value| options[:color] = value }
        opts.on("--fail-on-block") { options[:fail_on_block] = true }
      end.parse!(@argv)

      options.fetch(:input) if require_input
      options
    end

    def publish_review(payload:, options:)
      @stdout.puts render_review(payload:, options:)
      options[:fail_on_block] && blocked?(payload) ? 1 : 0
    end

    def render_review(payload:, options:)
      case options[:format]
      when "json"
        JSON.pretty_generate(payload)
      when "markdown"
        Github::CommentRenderer.markdown(payload:, context: review_context(payload))
      else
        TerminalRenderer.call(payload:, color: options[:color], io: @stdout)
      end
    end

    def blocked?(payload)
      payload.dig("result", "merge_recommendation") == "block"
    end

    def read_measurements(path)
      parsed = JSON.parse(File.read(path))
      parsed.fetch("measurements", parsed)
    end

    def read_review_payload(path)
      parsed = JSON.parse(File.read(path))
      payload = parsed["payload"].is_a?(Hash) ? parsed.fetch("payload") : parsed
      payload.fetch("result")
      payload.fetch("executions")
      payload
    end

    def review_context(payload)
      executions = payload.fetch("executions")
      baseline = executions.fetch("baseline")
      candidate = executions.fetch("candidate")

      {
        baseline_label: baseline["ref"] || baseline["subject"],
        baseline_sha: baseline["sha"],
        candidate_label: candidate["ref"] || candidate["subject"],
        candidate_sha: candidate["sha"]
      }.compact
    end

    def usage
      <<~USAGE.strip
        Usage:
          bin/rundiff diff --baseline FILE --candidate FILE [--format markdown|json]
          bin/rundiff review --input FILE [--format terminal|markdown|json] [--color auto|always|never]
          bin/rundiff demo [--format terminal|markdown|json] [--color auto|always|never] [--output FILE]
      USAGE
    end
  end
end
