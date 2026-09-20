module RunDiff
  class RuleRegistry
    SIGNALS = {
      "duration_ms" => {
        id: "performance.wall_time.regression",
        legacy_reason_code: "PERFORMANCE_REGRESSION",
        threshold_percent: 20.0,
        threshold_absolute: 20.0,
        severity: "high",
        domains: %w[runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: [],
        change_kind: "increase"
      },
      "process_cpu_ms" => {
        decision: false,
        optional: true,
        domains: %w[runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[cpu]
      },
      "thread_cpu_ms" => {
        id: "resource.cpu.time.regression",
        legacy_reason_code: "CPU_TIME_REGRESSION",
        threshold_percent: 30.0,
        threshold_absolute: 10.0,
        severity: "medium",
        optional: true,
        domains: %w[runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[cpu],
        change_kind: "increase"
      },
      "queue_wait_ms" => {
        id: "async.queue.wait.regression",
        legacy_reason_code: "QUEUE_WAIT_REGRESSION",
        threshold_percent: 20.0,
        threshold_absolute: 20.0,
        severity: "medium",
        optional: true,
        domains: %w[async],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[queue],
        change_kind: "increase"
      },
      "scheduled_delay_ms" => {
        decision: false,
        optional: true,
        domains: %w[async],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[queue]
      },
      "dispatch_wait_ms" => {
        id: "async.dispatch.wait.regression",
        legacy_reason_code: "DISPATCH_WAIT_REGRESSION",
        threshold_percent: 20.0,
        threshold_absolute: 20.0,
        severity: "medium",
        optional: true,
        domains: %w[async],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[queue],
        change_kind: "increase"
      },
      "worker_wall_ms" => {
        id: "async.worker.wall_time.regression",
        legacy_reason_code: "WORKER_LATENCY_REGRESSION",
        threshold_percent: 20.0,
        threshold_absolute: 20.0,
        severity: "medium",
        optional: true,
        domains: %w[async runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: [],
        change_kind: "increase"
      },
      "worker_process_cpu_ms" => {
        decision: false,
        optional: true,
        domains: %w[async runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[cpu]
      },
      "worker_thread_cpu_ms" => {
        id: "resource.cpu.time.regression",
        legacy_reason_code: "CPU_TIME_REGRESSION",
        threshold_percent: 30.0,
        threshold_absolute: 10.0,
        severity: "medium",
        optional: true,
        domains: %w[async runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[cpu],
        change_kind: "increase"
      },
      "sql_queries" => {
        id: "database.query.count.regression",
        legacy_reason_code: "DATABASE_QUERY_REGRESSION",
        threshold_percent: 25.0,
        severity: "high",
        domains: %w[database],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[database io],
        change_kind: "increase"
      },
      "background_jobs" => {
        id: "side_effect.background_job.count.changed",
        legacy_reason_code: "SIDE_EFFECT_CHANGED",
        threshold_absolute: 0,
        severity: "medium",
        domains: %w[async application],
        quality_dimensions: %w[functional_suitability reliability],
        resources: %w[queue],
        change_kind: "increase"
      },
      "emails" => {
        id: "side_effect.email.count.changed",
        legacy_reason_code: "SIDE_EFFECT_CHANGED",
        threshold_absolute: 0,
        severity: "high",
        domains: %w[application external_dependency],
        quality_dimensions: %w[functional_suitability reliability],
        resources: %w[external_service],
        change_kind: "increase"
      },
      "http_requests" => {
        id: "network.request.count.changed",
        legacy_reason_code: "NETWORK_BEHAVIOR_CHANGED",
        threshold_percent: 25.0,
        severity: "medium",
        domains: %w[network external_dependency],
        quality_dimensions: %w[performance_efficiency reliability],
        resources: %w[network external_service],
        change_kind: "increase"
      },
      "errors" => {
        id: "runtime.error.new",
        legacy_reason_code: "NEW_RUNTIME_ERROR",
        threshold_absolute: 0,
        severity: "critical",
        domains: %w[runtime application],
        quality_dimensions: %w[reliability],
        resources: [],
        change_kind: "appeared"
      }
    }.freeze

    FACET_KEYS = %i[domains quality_dimensions resources change_kind].freeze

    def self.each_signal(&block)
      SIGNALS.each(&block)
    end

    def self.fetch(signal)
      SIGNALS.fetch(signal.to_s)
    end

    def self.rule_id_for(signal)
      fetch(signal).fetch(:id)
    end

    def self.facets_for(signal)
      definition = fetch(signal)

      FACET_KEYS.each_with_object({}) do |key, facets|
        next unless definition.key?(key)

        facets[key.to_s] = definition.fetch(key)
      end
    end
  end
end
