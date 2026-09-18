module RunDiff
  module Github
    class CommentRenderer
      MARKER = "<!-- rundiff:behavioral-diff:v1 -->".freeze
      SIGNAL_LABELS = {
        "duration_ms" => "Request wall time",
        "process_cpu_ms" => "Request process CPU",
        "thread_cpu_ms" => "Request thread CPU",
        "queue_wait_ms" => "Enqueue → worker start (aggregate)",
        "scheduled_delay_ms" => "Scheduled delay",
        "dispatch_wait_ms" => "Eligible → worker start (dispatch)",
        "worker_wall_ms" => "Worker wall time",
        "worker_process_cpu_ms" => "Worker process CPU",
        "worker_thread_cpu_ms" => "Worker thread CPU",
        "sql_queries" => "SQL queries",
        "background_jobs" => "Background jobs",
        "emails" => "Emails",
        "http_requests" => "HTTP requests",
        "errors" => "Runtime errors"
      }.freeze
      SEVERITY_ICONS = {
        "critical" => "🔴",
        "high" => "🔴",
        "medium" => "🟠",
        "low" => "🟡"
      }.freeze
      ASYNC_DELTA_CLASSIFICATIONS = %w[
        scheduled_delay_change
        dispatch_wait_regression
        enqueue_to_start_regression
        worker_runtime_regression
        mixed_async_regression
      ].freeze
      ASYNC_REGRESSION_CLASSIFICATIONS = ASYNC_DELTA_CLASSIFICATIONS.reject { |value| value == "scheduled_delay_change" }.freeze

      def self.markdown(payload:, context: {})
        new(payload:, context:).markdown
      end

      def initialize(payload:, context: {})
        @payload = payload
        @context = context.transform_keys(&:to_s)
      end

      def markdown
        lines = [ MARKER, "## 🟣 RunDiff · Behavioral Review", "", summary_callout, "" ]
        lines.concat(signal_table)
        lines.concat(runtime_diagnosis_section)
        lines.concat(findings_section)
        lines.concat(execution_section)
        lines.concat(bootstrap_note) if bootstrap_baseline?
        lines.concat(footer)
        lines.join("\n")
      end

      private

      def result
        @payload.fetch("result")
      end

      def findings
        result.fetch("findings")
      end

      def executions
        @payload.fetch("executions")
      end

      def summary_callout
        if findings.empty?
          "> [!TIP]\n> **No behavioral regression detected.** Merge recommendation: **ALLOW**."
        else
          counts = findings.group_by { |finding| finding.fetch("severity") }.transform_values(&:size)
          severity_summary = %w[critical high medium low].filter_map do |severity|
            "#{counts.fetch(severity)} #{severity}" if counts.key?(severity)
          end.join(" · ")
          regression_label = findings.one? ? "regression" : "regressions"

          confidence = if findings.all? { |finding| finding.fetch("confidence", "deterministic") == "single_sample_timing" }
            " · timing evidence is single-sample and review-only"
          else
            ""
          end

          "> [!WARNING]\n> **Behavior changed while the functional scenario still passes.** " \
            "Merge recommendation: **#{result.fetch("merge_recommendation").upcase}** · " \
            "#{findings.size} #{regression_label} · #{severity_summary}#{confidence}."
        end
      end

      def signal_table
        lines = [
          "| Signal | Baseline | PR candidate | Change | Verdict |",
          "| --- | ---: | ---: | ---: | --- |"
        ]

        result.fetch("signals").each do |signal, values|
          verdict = if !values.fetch("available", true)
            "➖ Unavailable"
          elsif !values.fetch("decision_relevant", true)
            "ℹ️ Observed"
          elsif values.fetch("regression")
            "⚠️ Regression"
          else
            "✅ Stable"
          end
          lines << "| **#{SIGNAL_LABELS.fetch(signal, signal)}** | #{format_value(signal, values.fetch("baseline"))} | " \
            "#{format_value(signal, values.fetch("candidate"))} | **#{values.fetch("display_delta")}** | #{verdict} |"
        end

        [ "### Runtime diff", "", *lines, "" ]
      end

      def runtime_diagnosis_section
        diagnosis = result.fetch("runtime_diagnosis", {})
        return [] if diagnosis.empty?

        lines = [ "### Runtime diagnosis", "", "| Scope | Baseline | Candidate | Candidate CPU ratio |", "| --- | --- | --- | ---: |" ]
        %w[request worker].each do |scope|
          profile = diagnosis[scope]
          next unless profile

          baseline = profile.fetch("baseline")
          candidate = profile.fetch("candidate")
          lines << "| #{scope.capitalize} | #{runtime_classification(baseline)} | #{runtime_classification(candidate)} | " \
            "#{format_ratio(candidate.fetch("cpu_ratio_percent"))} |"
        end

        if (async_profile = diagnosis["async"])
          baseline = async_profile.fetch("baseline")
          candidate = async_profile.fetch("candidate")
          lines.concat([
            "",
            "| Async composition | Baseline | Candidate | Candidate enqueue-to-start share |",
            "| --- | --- | --- | ---: |",
            "| Enqueue → worker start vs worker runtime | #{async_classification(baseline)} | #{async_classification(candidate)} | " \
              "#{format_ratio(candidate.fetch("queue_share_percent"))} |"
          ])
        end

        lines.concat(async_delta_lines(diagnosis["async_delta"]))
        lines << ""
        lines
      end

      def async_delta_lines(delta)
        return [] unless delta && ASYNC_DELTA_CLASSIFICATIONS.include?(delta.fetch("classification", "unknown"))

        split_async_delta?(delta) ? split_async_delta_lines(delta) : legacy_async_delta_lines(delta)
      end

      def split_async_delta?(delta)
        delta.key?("scheduled_delay_delta_ms") && delta.key?("dispatch_wait_delta_ms")
      end

      def split_async_delta_lines(delta)
        classification = delta.fetch("classification")
        scheduled_share = delta.fetch("scheduled_delay_delta_share_percent")
        dispatch_share = delta.fetch("dispatch_wait_delta_share_percent")
        worker_share = delta.fetch("worker_runtime_delta_share_percent")
        prefix = classification == "scheduled_delay_change" ? "Change source" : "Regression source"

        [
          "",
          "#### Async change attribution",
          "",
          "> **#{prefix}: #{async_delta_label(classification)}.** " \
            "Positive async latency growth: **#{format_ms_delta(delta.fetch("positive_async_delta_ms"))}**.",
          "",
          "| Stage | Delta | Share of positive async growth |",
          "| --- | ---: | ---: |",
          "| Scheduled delay | #{format_ms_delta(delta.fetch("scheduled_delay_delta_ms"))} | #{format_ratio(scheduled_share)} |",
          "| Eligible → worker start | #{format_ms_delta(delta.fetch("dispatch_wait_delta_ms"))} | #{format_ratio(dispatch_share)} |",
          "| Worker runtime | #{format_ms_delta(delta.fetch("worker_wall_delta_ms"))} | #{format_ratio(worker_share)} |"
        ]
      end

      def legacy_async_delta_lines(delta)
        enqueue_share = delta.fetch("enqueue_to_start_delta_share_percent")
        worker_share = 100.0 - enqueue_share

        [
          "",
          "#### Async change attribution",
          "",
          "> **Regression source: #{async_delta_label(delta.fetch("classification"))}.** " \
            "Positive async latency growth: **#{format_ms_delta(delta.fetch("positive_async_delta_ms"))}**.",
          "",
          "| Stage | Delta | Share of positive async growth |",
          "| --- | ---: | ---: |",
          "| Enqueue → worker start | #{format_ms_delta(delta.fetch("queue_wait_delta_ms"))} | #{format_ratio(enqueue_share)} |",
          "| Worker runtime | #{format_ms_delta(delta.fetch("worker_wall_delta_ms"))} | #{format_ratio(worker_share)} |"
        ]
      end

      def async_delta_label(classification)
        case classification
        when "scheduled_delay_change"
          "declared scheduled delay"
        when "dispatch_wait_regression"
          "dispatch wait after eligibility"
        when "enqueue_to_start_regression"
          "enqueue-to-start stage"
        when "worker_runtime_regression"
          "worker runtime"
        else
          "mixed async stages"
        end
      end

      def findings_section
        return [] if findings.empty?

        lines = [ "<details open>", "<summary><strong>Findings</strong> · #{findings.size} detected</summary>", "" ]
        findings.each do |finding|
          severity = finding.fetch("severity")
          signal = finding.fetch("signal")
          confidence = finding.fetch("confidence", "deterministic") == "single_sample_timing" ?
            " · _single-sample timing, review-only_" : ""
          lines << "- #{SEVERITY_ICONS.fetch(severity, "⚪")} **#{severity.upcase}** · " \
            "`#{finding.fetch("reason_code")}` · **#{SIGNAL_LABELS.fetch(signal, signal)}** · " \
            "#{format_value(signal, finding.fetch("baseline"))} → #{format_value(signal, finding.fetch("candidate"))} " \
            "(#{display_percent(finding.fetch("delta_percent"))})#{confidence}"
        end
        lines.concat([ "", "</details>", "" ])
      end

      def execution_section
        baseline = executions.fetch("baseline")
        candidate = executions.fetch("candidate")
        lines = [
          "<details>",
          "<summary><strong>Execution context</strong></summary>",
          "",
          "| Subject | Ref | SHA | Functional | Correlation |",
          "| --- | --- | --- | --- | --- |",
          "| Baseline | `#{context("baseline_label", "dogfood baseline")}` | #{sha_markdown(context("baseline_sha", "synthetic"))} | " \
            "#{status_icon(baseline)} | #{correlation_icon(baseline)} |",
          "| Candidate | `#{context("candidate_label", "candidate")}` | #{sha_markdown(context("candidate_sha", "unknown"))} | " \
            "#{status_icon(candidate)} | #{correlation_icon(candidate)} |",
          "",
          "Run: `#{@payload.fetch("run_id")}`  ",
          "Scenario: `#{@payload.fetch("scenario_id")}`"
        ]
        lines << "Evidence: #{context("execution_mode")}" if context("execution_mode")
        lines.concat([ "", "</details>", "" ])
      end

      def bootstrap_note
        [
          "> [!NOTE]",
          "> This is the bootstrap dogfood run. The PR base currently has no runnable Rails subject, so the baseline execution is a deterministic baseline profile, not a process started from `main`. Git base/head SHAs are still attached. Once this PR lands, subsequent PRs can run executable `main` vs PR head directly.",
          ""
        ]
      end

      def footer
        links = []
        links << "[Actions run](#{context("run_url")})" if context("run_url")
        links << "[Source diff](#{source_diff_url})" if source_diff_url
        links << "`#{context("repository")}`" if context("repository")
        links << "PR ##{context("pr_number")}" if context("pr_number")

        [ "---", "<sub>#{([ "RunDiff v0.0.1" ] + links).join(" · ")}</sub>" ]
      end

      def format_value(signal, value)
        return "n/a" if value.nil?

        signal.end_with?("_ms") ? format("%.1f ms", value) : value.to_i.to_s
      end

      def format_ms_delta(value)
        return "n/a" if value.nil?
        return "unchanged" if value.zero?

        sign = value.positive? ? "+" : ""
        "#{sign}#{format("%.1f", value)} ms"
      end

      def runtime_classification(profile)
        profile.fetch("classification", "unknown").tr("_", " ")
      end

      def async_classification(profile)
        case profile.fetch("classification", "unknown")
        when "queue_bound"
          "enqueue-to-start dominates"
        when "worker_bound"
          "worker runtime dominates"
        when "mixed_async"
          "mixed async"
        when "insufficient_signal"
          "insufficient signal"
        else
          "unknown"
        end
      end

      def format_ratio(value)
        value.nil? ? "n/a" : "#{format("%.1f", value)}%"
      end

      def display_percent(value)
        value.positive? ? "+#{value}%" : "#{value}%"
      end

      def status_icon(execution)
        execution.fetch("status") == "passed" ? "✅ passed" : "❌ failed"
      end

      def correlation_icon(execution)
        execution.fetch("correlation_confirmed") ? "✅ confirmed" : "❌ missing"
      end

      def sha_markdown(value)
        value = value.to_s
        return "`#{short_sha(value)}`" unless linkable_sha?(value)

        "[`#{short_sha(value)}`](https://github.com/#{context("repository")}/commit/#{value})"
      end

      def short_sha(value)
        value.to_s == "synthetic" ? value : value.to_s[0, 8]
      end

      def source_diff_url
        baseline_sha = context("baseline_sha").to_s
        candidate_sha = context("candidate_sha").to_s
        return unless linkable_sha?(baseline_sha) && linkable_sha?(candidate_sha)

        "https://github.com/#{context("repository")}/compare/#{baseline_sha}...#{candidate_sha}"
      end

      def linkable_sha?(value)
        context("repository") && !value.empty? && !%w[synthetic unknown].include?(value)
      end

      def bootstrap_baseline?
        context("bootstrap_baseline") == true || context("bootstrap_baseline") == "1"
      end

      def context(key, fallback = nil)
        @context.fetch(key, fallback)
      end
    end
  end
end
