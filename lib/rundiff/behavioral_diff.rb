require_relative "async_delta_diagnosis"
require_relative "async_diagnosis"
require_relative "runtime_diagnosis"

module RunDiff
  class BehavioralDiff
    SIGNALS = {
      "duration_ms" => {
        reason_code: "PERFORMANCE_REGRESSION",
        threshold_percent: 20.0,
        threshold_absolute: 20.0,
        severity: "high"
      },
      "process_cpu_ms" => { decision: false, optional: true },
      "thread_cpu_ms" => {
        reason_code: "CPU_TIME_REGRESSION",
        threshold_percent: 30.0,
        threshold_absolute: 10.0,
        severity: "medium",
        optional: true
      },
      "queue_wait_ms" => {
        reason_code: "QUEUE_WAIT_REGRESSION",
        threshold_percent: 20.0,
        threshold_absolute: 20.0,
        severity: "medium",
        optional: true
      },
      "scheduled_delay_ms" => { decision: false, optional: true },
      "dispatch_wait_ms" => {
        reason_code: "DISPATCH_WAIT_REGRESSION",
        threshold_percent: 20.0,
        threshold_absolute: 20.0,
        severity: "medium",
        optional: true
      },
      "worker_wall_ms" => {
        reason_code: "WORKER_LATENCY_REGRESSION",
        threshold_percent: 20.0,
        threshold_absolute: 20.0,
        severity: "medium",
        optional: true
      },
      "worker_process_cpu_ms" => { decision: false, optional: true },
      "worker_thread_cpu_ms" => {
        reason_code: "CPU_TIME_REGRESSION",
        threshold_percent: 30.0,
        threshold_absolute: 10.0,
        severity: "medium",
        optional: true
      },
      "sql_queries" => { reason_code: "DATABASE_QUERY_REGRESSION", threshold_percent: 25.0, severity: "high" },
      "background_jobs" => { reason_code: "SIDE_EFFECT_CHANGED", threshold_absolute: 0, severity: "medium" },
      "emails" => { reason_code: "SIDE_EFFECT_CHANGED", threshold_absolute: 0, severity: "high" },
      "http_requests" => { reason_code: "NETWORK_BEHAVIOR_CHANGED", threshold_percent: 25.0, severity: "medium" },
      "response_bytes" => {
        reason_code: "RESPONSE_SIZE_INCREASE",
        threshold_percent: 25.0,
        threshold_absolute: 32.0,
        severity: "medium",
        optional: true
      },
      "errors" => { reason_code: "NEW_RUNTIME_ERROR", threshold_absolute: 0, severity: "critical" }
    }.freeze

    def self.call(baseline:, candidate:)
      new(baseline:, candidate:).call
    end

    def initialize(baseline:, candidate:)
      @baseline = stringify_keys(baseline)
      @candidate = stringify_keys(candidate)
    end

    def call
      signals = {}
      findings = []

      SIGNALS.each do |signal, policy|
        unless comparable?(signal, policy)
          signals[signal] = unavailable_signal(signal, policy)
          next
        end

        baseline_value = numeric(@baseline.fetch(signal, 0))
        candidate_value = numeric(@candidate.fetch(signal, 0))
        delta = candidate_value - baseline_value
        delta_percent = percent_change(baseline_value, candidate_value)
        decision_relevant = decision_relevant?(signal, policy)
        regression = decision_relevant && regression?(baseline_value, candidate_value, policy)

        signals[signal] = {
          "baseline" => baseline_value,
          "candidate" => candidate_value,
          "delta" => delta,
          "delta_percent" => delta_percent,
          "display_delta" => display_delta(delta, delta_percent),
          "available" => true,
          "decision_relevant" => decision_relevant,
          "regression" => regression
        }

        next unless regression

        findings << {
          "type" => "behavioral_regression",
          "reason_code" => policy.fetch(:reason_code),
          "severity" => policy.fetch(:severity),
          "finding_severity" => finding_severity(policy.fetch(:severity)),
          "signal" => signal,
          "baseline" => baseline_value,
          "candidate" => candidate_value,
          "delta" => delta,
          "delta_percent" => delta_percent
        }
      end

      {
        "schema_version" => "1",
        "status" => "completed",
        "decision" => findings.empty? ? "no_regression" : "regression",
        "merge_recommendation" => block_merge?(findings) ? "block" : "allow",
        "signals" => signals,
        "runtime_diagnosis" => runtime_diagnosis(signals),
        "findings" => findings,
        "warning_count" => findings.count { |finding| finding.fetch("finding_severity") == "WARNING" },
        "blocking_count" => findings.count { |finding| finding.fetch("finding_severity") == "BLOCKING" },
        "recommended_action" => recommended_action(findings)
      }
    end

    private

    def stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    def comparable?(signal, policy)
      return true unless policy.fetch(:optional, false)

      @baseline.key?(signal) && @candidate.key?(signal)
    end

    def decision_relevant?(signal, policy)
      return false if signal == "queue_wait_ms" && split_queue_stage_available?

      policy.fetch(:decision, true)
    end

    def split_queue_stage_available?
      @baseline.key?("dispatch_wait_ms") && @candidate.key?("dispatch_wait_ms")
    end

    def unavailable_signal(signal, policy)
      {
        "baseline" => @baseline.key?(signal) ? numeric(@baseline.fetch(signal)) : nil,
        "candidate" => @candidate.key?(signal) ? numeric(@candidate.fetch(signal)) : nil,
        "delta" => nil,
        "delta_percent" => nil,
        "display_delta" => "n/a",
        "available" => false,
        "decision_relevant" => policy.fetch(:decision, true),
        "regression" => false
      }
    end

    def numeric(value)
      return value if value.is_a?(Numeric)

      Float(value)
    rescue ArgumentError, TypeError
      0
    end

    def percent_change(baseline, candidate)
      return 0.0 if baseline.zero? && candidate.zero?
      return 100.0 if baseline.zero? && candidate.positive?

      (((candidate - baseline) / baseline.to_f) * 100).round(1)
    end

    def regression?(baseline, candidate, policy)
      return false unless candidate > baseline

      delta = candidate - baseline
      absolute_regression = !policy.key?(:threshold_absolute) || delta > policy.fetch(:threshold_absolute)
      percentage_regression = !policy.key?(:threshold_percent) ||
        percent_change(baseline, candidate) > policy.fetch(:threshold_percent)

      absolute_regression && percentage_regression
    end

    def display_delta(delta, delta_percent)
      return "unchanged" if delta.zero?

      sign = delta.positive? ? "+" : ""
      "#{sign}#{delta_percent}%"
    end

    def runtime_diagnosis(signals)
      {
        "request" => runtime_scope_diagnosis(
          wall: signals.fetch("duration_ms"),
          thread_cpu: signals.fetch("thread_cpu_ms")
        ),
        "async" => async_scope_diagnosis(
          queue_wait: signals.fetch("queue_wait_ms"),
          worker_wall: signals.fetch("worker_wall_ms")
        ),
        "async_delta" => AsyncDeltaDiagnosis.call(
          queue_wait: signals.fetch("queue_wait_ms"),
          scheduled_delay: signals.fetch("scheduled_delay_ms"),
          dispatch_wait: signals.fetch("dispatch_wait_ms"),
          worker_wall: signals.fetch("worker_wall_ms")
        ),
        "worker" => runtime_scope_diagnosis(
          wall: signals.fetch("worker_wall_ms"),
          thread_cpu: signals.fetch("worker_thread_cpu_ms")
        )
      }
    end

    def runtime_scope_diagnosis(wall:, thread_cpu:)
      {
        "baseline" => runtime_profile(wall, thread_cpu, "baseline"),
        "candidate" => runtime_profile(wall, thread_cpu, "candidate")
      }
    end

    def async_scope_diagnosis(queue_wait:, worker_wall:)
      {
        "baseline" => async_profile(queue_wait, worker_wall, "baseline"),
        "candidate" => async_profile(queue_wait, worker_wall, "candidate")
      }
    end

    def runtime_profile(wall, thread_cpu, side)
      return RuntimeDiagnosis.call(wall_ms: nil, thread_cpu_ms: nil) unless wall.fetch("available", true) && thread_cpu.fetch("available", true)

      RuntimeDiagnosis.call(
        wall_ms: wall[side],
        thread_cpu_ms: thread_cpu[side]
      ).slice("classification", "cpu_ratio_percent")
    end

    def async_profile(queue_wait, worker_wall, side)
      return AsyncDiagnosis.call(queue_wait_ms: nil, worker_wall_ms: nil) unless queue_wait.fetch("available", true) && worker_wall.fetch("available", true)

      AsyncDiagnosis.call(
        queue_wait_ms: queue_wait[side],
        worker_wall_ms: worker_wall[side]
      ).slice("classification", "queue_share_percent")
    end

    def finding_severity(legacy)
      return "BLOCKING" if %w[critical high].include?(legacy)
      return "WARNING" if legacy == "medium"

      "INFO"
    end

    def block_merge?(findings)
      findings.any? { |finding| finding.fetch("finding_severity") == "BLOCKING" }
    end

    def recommended_action(findings)
      primary = findings.min_by do |finding|
        %w[critical high medium low].index(finding.fetch("severity")) || 99
      end

      return { "type" => "none" } unless primary

      {
        "type" => "investigate",
        "reason_code" => primary.fetch("reason_code"),
        "signal" => primary.fetch("signal")
      }
    end
  end
end
