module RunDiff
  class RuleRegistry
    RULES = {
      "duration_ms" => {
        id: "performance.wall_time.regression",
        domains: %w[runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: [],
        change_kind: "increase"
      },
      "thread_cpu_ms" => {
        id: "resource.cpu.time.regression",
        domains: %w[runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[cpu],
        change_kind: "increase"
      },
      "worker_thread_cpu_ms" => {
        id: "resource.cpu.time.regression",
        domains: %w[runtime async],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[cpu],
        change_kind: "increase"
      },
      "queue_wait_ms" => {
        id: "async.queue.wait.regression",
        domains: %w[async],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[queue],
        change_kind: "increase"
      },
      "dispatch_wait_ms" => {
        id: "async.dispatch.wait.regression",
        domains: %w[async],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[queue],
        change_kind: "increase"
      },
      "worker_wall_ms" => {
        id: "async.worker.wall_time.regression",
        domains: %w[async runtime],
        quality_dimensions: %w[performance_efficiency],
        resources: [],
        change_kind: "increase"
      },
      "sql_queries" => {
        id: "database.query.count.regression",
        domains: %w[database],
        quality_dimensions: %w[performance_efficiency],
        resources: %w[database io],
        change_kind: "increase"
      },
      "background_jobs" => {
        id: "side_effect.background_job.count.changed",
        domains: %w[async application],
        quality_dimensions: %w[functional_suitability reliability],
        resources: %w[queue],
        change_kind: "increase"
      },
      "emails" => {
        id: "side_effect.email.count.changed",
        domains: %w[application external_dependency],
        quality_dimensions: %w[functional_suitability reliability],
        resources: %w[external_service],
        change_kind: "increase"
      },
      "http_requests" => {
        id: "network.request.count.changed",
        domains: %w[network external_dependency],
        quality_dimensions: %w[performance_efficiency reliability],
        resources: %w[network external_service],
        change_kind: "increase"
      },
      "errors" => {
        id: "runtime.error.new",
        domains: %w[runtime application],
        quality_dimensions: %w[reliability],
        resources: [],
        change_kind: "appeared"
      }
    }.freeze

    def self.fetch(signal)
      RULES.fetch(signal.to_s)
    end

    def self.rule_id_for(signal)
      fetch(signal).fetch(:id)
    end
  end
end
