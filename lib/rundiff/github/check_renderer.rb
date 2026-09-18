module RunDiff
  module Github
    class CheckRenderer
      NAME = "RunDiff / Behavioral Review".freeze
      CONCLUSIONS = {
        "allow" => "success",
        "review" => "neutral",
        "block" => "failure"
      }.freeze
      ANNOTATION_LEVELS = {
        "critical" => "failure",
        "high" => "failure",
        "medium" => "warning",
        "low" => "notice"
      }.freeze
      SIGNAL_LABELS = CommentRenderer::SIGNAL_LABELS
      ASYNC_DELTA_CLASSIFICATIONS = CommentRenderer::ASYNC_DELTA_CLASSIFICATIONS

      def self.call(payload:, run_url: nil)
        new(payload:, run_url:).call
      end

      def initialize(payload:, run_url: nil)
        @payload = payload
        @run_url = run_url
      end

      def call
        {
          "name" => NAME,
          "conclusion" => CONCLUSIONS.fetch(result.fetch("merge_recommendation")),
          "title" => title,
          "summary" => summary,
          "annotations" => annotations
        }
      end

      private

      def result
        @payload.fetch("result")
      end

      def findings
        result.fetch("findings")
      end

      def title
        case result.fetch("merge_recommendation")
        when "allow"
          "No behavioral regression detected"
        when "review"
          "Behavior changed - review required"
        when "block"
          "Behavioral regression detected"
        end
      end

      def summary
        lines = [ decision_line ]
        lines << "[Open execution](#{@run_url})" if @run_url
        lines.concat([ "", "| Signal | Baseline | Candidate | Change |", "| --- | ---: | ---: | ---: |" ])

        result.fetch("signals").each do |signal, values|
          marker = if !values.fetch("available", true)
            " ➖"
          elsif !values.fetch("decision_relevant", true)
            " ℹ️"
          elsif values.fetch("regression")
            " ⚠️"
          else
            ""
          end
          lines << "| #{SIGNAL_LABELS.fetch(signal, signal)} | #{format_value(signal, values.fetch("baseline"))} | " \
            "#{format_value(signal, values.fetch("candidate"))} | #{values.fetch("display_delta")}#{marker} |"
        end

        lines.concat(runtime_diagnosis_lines)

        unless findings.empty?
          lines.concat([ "", "### Findings", "" ])
          findings.each do |finding|
            lines << "- **#{finding.fetch("severity").upcase}** - `#{finding.fetch("reason_code")}` - " \
              "#{SIGNAL_LABELS.fetch(finding.fetch("signal"), finding.fetch("signal"))}"
          end
        end

        lines.join("\n")
      end

      def runtime_diagnosis_lines
        diagnosis = result.fetch("runtime_diagnosis", {})
        return [] if diagnosis.empty?

        lines = [ "", "### Runtime diagnosis", "", "| Scope | Baseline | Candidate | Candidate CPU ratio |", "| --- | --- | --- | ---: |" ]
        %w[request worker].each do |scope|
          profile = diagnosis[scope]
          next unless profile

          baseline = profile.fetch("baseline")
          candidate = profile.fetch("candidate")
          lines << "| #{scope.capitalize} | #{classification(baseline)} | #{classification(candidate)} | #{format_ratio(candidate.fetch("cpu_ratio_percent"))} |"
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
        prefix = classification == "scheduled_delay_change" ? "Change source" : "Regression source"

        [
          "",
          "### Async change attribution",
          "",
          "**#{prefix}:** #{async_delta_label(classification)}. " \
            "Positive async latency growth: **#{format_ms_delta(delta.fetch("positive_async_delta_ms"))}**.",
          "",
          "| Stage | Delta | Share of positive async growth |",
          "| --- | ---: | ---: |",
          "| Scheduled delay | #{format_ms_delta(delta.fetch("scheduled_delay_delta_ms"))} | #{format_ratio(delta.fetch("scheduled_delay_delta_share_percent"))} |",
          "| Eligible → worker start | #{format_ms_delta(delta.fetch("dispatch_wait_delta_ms"))} | #{format_ratio(delta.fetch("dispatch_wait_delta_share_percent"))} |",
          "| Worker runtime | #{format_ms_delta(delta.fetch("worker_wall_delta_ms"))} | #{format_ratio(delta.fetch("worker_runtime_delta_share_percent"))} |"
        ]
      end

      def legacy_async_delta_lines(delta)
        enqueue_share = delta.fetch("enqueue_to_start_delta_share_percent")
        worker_share = 100.0 - enqueue_share

        [
          "",
          "### Async change attribution",
          "",
          "**Regression source:** #{async_delta_label(delta.fetch("classification"))}. " \
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

      def annotations
        findings.filter_map do |finding|
          source = finding["source"]
          next unless source

          {
            "path" => source.fetch("path"),
            "start_line" => source.fetch("start_line"),
            "end_line" => source.fetch("end_line"),
            "annotation_level" => ANNOTATION_LEVELS.fetch(finding.fetch("severity"), "warning"),
            "title" => "RunDiff: #{SIGNAL_LABELS.fetch(finding.fetch("signal"), finding.fetch("signal"))}",
            "message" => annotation_message(finding)
          }
        end.first(50)
      end

      def annotation_message(finding)
        signal = finding.fetch("signal")
        "#{finding.fetch("reason_code")}: #{SIGNAL_LABELS.fetch(signal, signal)} changed from " \
          "#{format_value(signal, finding.fetch("baseline"))} to #{format_value(signal, finding.fetch("candidate"))} " \
          "(#{display_percent(finding.fetch("delta_percent"))})."
      end

      def decision_line
        recommendation = result.fetch("merge_recommendation").upcase
        return "**#{recommendation}** - no behavioral regression detected." if findings.empty?

        primary = findings.first
        signal = primary.fetch("signal")
        label = SIGNAL_LABELS.fetch(signal, signal)
        "**#{recommendation}** - tests passed, but runtime behavior changed. " \
          "`#{primary.fetch("reason_code")}` · #{label} " \
          "#{format_value(signal, primary.fetch("baseline"))} → #{format_value(signal, primary.fetch("candidate"))} " \
          "(#{display_percent(primary.fetch("delta_percent"))})."
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

      def classification(profile)
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
    end
  end
end
