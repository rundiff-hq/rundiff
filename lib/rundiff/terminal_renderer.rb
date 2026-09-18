module RunDiff
  class TerminalRenderer
    SIGNAL_LABELS = {
      "sql_queries" => "SQL queries",
      "background_jobs" => "Background jobs",
      "emails" => "Emails",
      "http_requests" => "HTTP requests",
      "errors" => "Runtime errors",
      "duration_ms" => "Request wall time",
      "dispatch_wait_ms" => "Dispatch wait",
      "queue_wait_ms" => "Enqueue to worker",
      "worker_wall_ms" => "Worker wall time",
      "thread_cpu_ms" => "Request thread CPU",
      "worker_thread_cpu_ms" => "Worker thread CPU"
    }.freeze
    SIGNAL_ORDER = %w[
      sql_queries
      background_jobs
      emails
      http_requests
      errors
      duration_ms
      dispatch_wait_ms
      queue_wait_ms
      worker_wall_ms
      thread_cpu_ms
      worker_thread_cpu_ms
    ].freeze
    COLORS = {
      red: 31,
      green: 32,
      yellow: 33,
      dim: 2,
      bold: 1
    }.freeze

    def self.call(payload:, color: :auto, io: nil)
      new(payload:, color:, io:).call
    end

    def initialize(payload:, color: :auto, io: nil)
      @payload = payload
      @color = color.to_sym
      @io = io
    end

    def call
      lines = [
        paint("RunDiff Behavioral Review", :bold),
        "",
        decision_line,
        "Scenario  #{scenario_id}",
        ""
      ]
      lines.concat(signal_table)
      lines.concat(findings_section)
      lines.concat(evidence_section)
      lines.join("\n")
    end

    private

    def result
      @payload.fetch("result")
    end

    def executions
      @payload.fetch("executions", {})
    end

    def findings
      result.fetch("findings")
    end

    def scenario_id
      @payload.fetch("scenario_id", "unknown")
    end

    def recommendation
      result.fetch("merge_recommendation").upcase
    end

    def decision_line
      case recommendation
      when "BLOCK"
        paint("✕ BLOCK", :red, :bold) + functional_suffix("Tests passed, but runtime behavior changed.")
      when "REVIEW"
        paint("! REVIEW", :yellow, :bold) + functional_suffix("Behavior changed and needs review.")
      else
        paint("✓ ALLOW", :green, :bold) + "  No behavioral regression detected."
      end
    end

    def functional_suffix(message)
      functional_passed? ? "  #{message}" : "  Behavioral regression detected."
    end

    def signal_table
      rows = visible_signals.map do |signal, values|
        [
          SIGNAL_LABELS.fetch(signal, signal),
          format_value(signal, values.fetch("baseline")),
          format_value(signal, values.fetch("candidate")),
          values.fetch("display_delta"),
          verdict(values)
        ]
      end

      widths = [
        [ "SIGNAL".length, rows.map { |row| row[0].length }.max.to_i ].max,
        [ "BASELINE".length, rows.map { |row| row[1].length }.max.to_i ].max,
        [ "CANDIDATE".length, rows.map { |row| row[2].length }.max.to_i ].max,
        [ "CHANGE".length, rows.map { |row| row[3].length }.max.to_i ].max
      ]

      lines = [
        format(
          "%-#{widths[0]}s  %#{widths[1]}s  %#{widths[2]}s  %#{widths[3]}s  %s",
          "SIGNAL", "BASELINE", "CANDIDATE", "CHANGE", "VERDICT"
        )
      ]

      rows.each do |row|
        verdict_text = row[4] == "REGRESSION" ? paint(row[4], :red, :bold) : paint(row[4], :dim)
        lines << format(
          "%-#{widths[0]}s  %#{widths[1]}s  %#{widths[2]}s  %#{widths[3]}s  %s",
          row[0], row[1], row[2], row[3], verdict_text
        )
      end

      lines << ""
      lines
    end

    def visible_signals
      signals = result.fetch("signals")
      SIGNAL_ORDER.filter_map do |signal|
        values = signals[signal]
        next unless values
        next unless values.fetch("available", true)
        next if !values.fetch("decision_relevant", true) && !values.fetch("regression", false)

        [ signal, values ]
      end
    end

    def verdict(values)
      values.fetch("regression") ? "REGRESSION" : "stable"
    end

    def findings_section
      return [] if findings.empty?

      primary = findings.first
      lines = [ paint("Finding", :bold), "" ]
      findings.each do |finding|
        lines << "  #{paint(finding.fetch("reason_code"), :red, :bold)}"
        lines << "  #{finding_sentence(finding)}"
      end
      lines << ""
      lines << "Functional scenario: #{functional_passed? ? paint("PASSED", :green) : paint("FAILED", :red)}"
      lines << "Behavioral review:  #{paint(recommendation, recommendation_color)}"
      lines << ""
      lines
    end

    def finding_sentence(finding)
      delta = finding.fetch("delta")
      case finding.fetch("reason_code")
      when "DATABASE_QUERY_REGRESSION"
        "Candidate executed #{format_count(delta)} additional SQL #{delta.to_f.abs == 1 ? "query" : "queries"}."
      when "NEW_RUNTIME_ERROR"
        "Candidate introduced #{format_count(delta)} additional runtime #{delta.to_f.abs == 1 ? "error" : "errors"}."
      else
        signal = finding.fetch("signal")
        label = SIGNAL_LABELS.fetch(signal, signal)
        "#{label} changed from #{format_value(signal, finding.fetch("baseline"))} to " \
          "#{format_value(signal, finding.fetch("candidate"))} (#{display_percent(finding.fetch("delta_percent"))})."
      end
    end

    def evidence_section
      baseline = executions["baseline"]
      candidate = executions["candidate"]
      return [] unless baseline || candidate

      lines = [ paint("Evidence", :bold), "" ]
      lines << evidence_line("Baseline", baseline) if baseline
      lines << evidence_line("Candidate", candidate) if candidate
      lines
    end

    def evidence_line(label, execution)
      ref = execution["ref"] || execution["subject"] || label.downcase
      sha = execution["sha"]
      suffix = sha && !sha.empty? ? "  #{short_sha(sha)}" : ""
      "  #{label.ljust(9)} #{ref}#{suffix}"
    end

    def short_sha(value)
      value.to_s[0, 8]
    end

    def functional_passed?
      baseline = executions["baseline"]
      candidate = executions["candidate"]
      return true unless baseline && candidate

      baseline["status"] == "passed" && candidate["status"] == "passed"
    end

    def format_value(signal, value)
      return "n/a" if value.nil?

      if signal.end_with?("_ms")
        "#{format("%.1f", value)} ms"
      elsif value.is_a?(Numeric) && value.to_f != value.to_i
        format("%.1f", value)
      else
        value.to_i.to_s
      end
    end

    def format_count(value)
      numeric = value.to_f
      numeric == numeric.to_i ? numeric.to_i.to_s : format("%.1f", numeric)
    end

    def display_percent(value)
      value.to_f.positive? ? "+#{value}%" : "#{value}%"
    end

    def recommendation_color
      case recommendation
      when "BLOCK" then :red
      when "REVIEW" then :yellow
      else :green
      end
    end

    def paint(text, *styles)
      return text unless color_enabled?

      codes = styles.map { |style| COLORS.fetch(style) }
      "\e[#{codes.join(";")}m#{text}\e[0m"
    end

    def color_enabled?
      case @color
      when :always then true
      when :never then false
      when :auto then @io&.respond_to?(:tty?) && @io.tty?
      else
        false
      end
    end
  end
end
