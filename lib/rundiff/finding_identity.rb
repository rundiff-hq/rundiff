require "digest"

module RunDiff
  class FindingIdentity
    FINGERPRINT_VERSION = "finding-v1"

    def self.enrich!(finding:, scenario_id:, baseline:, candidate:)
      new(
        finding:,
        scenario_id:,
        baseline:,
        candidate:
      ).enrich!
    end

    def initialize(finding:, scenario_id:, baseline:, candidate:)
      @finding = finding
      @scenario_id = scenario_id.to_s
      @baseline = baseline
      @candidate = candidate
    end

    def enrich!
      @finding["fingerprint"] = fingerprint
      @finding["evidence_refs"] = evidence_refs
      @finding
    end

    private

    def fingerprint
      identity = [
        FINGERPRINT_VERSION,
        @scenario_id,
        @finding.fetch("rule_id"),
        @finding.fetch("signal")
      ].join("\0")

      "sha256:#{Digest::SHA256.hexdigest(identity)}"
    end

    def evidence_refs
      [
        measurement_ref(role: "baseline", execution: @baseline),
        measurement_ref(role: "candidate", execution: @candidate)
      ]
    end

    def measurement_ref(role:, execution:)
      {
        "kind" => "measurement",
        "role" => role,
        "execution_id" => execution.fetch("id").to_s,
        "signal" => @finding.fetch("signal")
      }
    end
  end
end
