require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"

module RunDiff
  module Demo
    class CustomerReviewRunner
      Error = Class.new(StandardError)

      def initialize(root: Pathname(__dir__).join("../../..").expand_path, stderr: $stderr)
        @root = Pathname(root).expand_path
        @stderr = stderr
      end

      def call(output_path: nil)
        if output_path
          output = Pathname(output_path).expand_path
          FileUtils.mkdir_p(output.dirname)
          run_proof(output:)
          JSON.parse(output.read)
        else
          Dir.mktmpdir("rundiff-demo-") do |directory|
            output = Pathname(directory).join("review.json")
            run_proof(output:)
            return JSON.parse(output.read)
          end
        end
      end

      private

      def run_proof(output:)
        @stderr.puts "RunDiff: running customer-like Rails + SQLite A/B proof..."

        stdout, stderr, status = Open3.capture3(
          { "RUNDIFF_OUTPUT" => output.to_s },
          "bundle",
          "exec",
          RbConfig.ruby,
          @root.join("script", "prove_rails_sqlite_subject.rb").to_s,
          chdir: @root.to_s
        )

        unless status.success?
          details = stderr.to_s.empty? ? stdout.to_s : stderr.to_s
          raise Error, "customer-like proof failed: #{details.strip}"
        end

        raise Error, "customer-like proof did not produce #{output}" unless output.file? && output.size.positive?

        @stderr.puts "RunDiff: captured real baseline/candidate runtime evidence."
      rescue Errno::ENOENT => error
        raise Error, "unable to run customer-like proof: #{error.message}"
      end
    end
  end
end
