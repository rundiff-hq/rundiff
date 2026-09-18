require "json"
require "optparse"
require_relative "behavioral_diff"
require_relative "report_renderer"

module Plywo
  class CLI
    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      case (command = @argv.shift)
      when "diff"
        run_diff
      when "version", "--version", "-v"
        @stdout.puts "rundiff 0.0.1"
        0
      else
        @stderr.puts usage
        command.nil? ? 0 : 2
      end
    rescue OptionParser::ParseError, KeyError, JSON::ParserError, Errno::ENOENT => error
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

    def read_measurements(path)
      parsed = JSON.parse(File.read(path))
      parsed.fetch("measurements", parsed)
    end

    def usage
      "Usage: bin/rundiff diff --baseline FILE --candidate FILE [--format markdown|json]"
    end
  end
end
