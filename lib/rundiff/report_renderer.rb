module RunDiff
  class ReportRenderer
    def self.markdown(result)
      new(result).markdown
    end

    def initialize(result)
      @result = result
    end

    def markdown
      lines = [ "## RunDiff Behavioral Diff", "" ]
      if findings.empty?
        lines << "✅ No behavioral regression detected."
      else
        lines << "🟡 Tests passed, but RunDiff detected **#{findings.size} behavioral regressions**."
      end

      lines += [ "", "| Signal | Baseline | Candidate | Change |", "| --- | ---: | ---: | ---: |" ]
      @result.fetch("signals").each do |signal, values|
        marker = values.fetch("regression") ? " ⚠" : ""
        lines << "| `#{signal}` | #{values.fetch("baseline")} | #{values.fetch("candidate")} | #{values.fetch("display_delta")}#{marker} |"
      end

      unless findings.empty?
        lines += [ "", "### Findings", "" ]
        findings.each do |finding|
          lines << "- **#{finding.fetch("reason_code")}** · `#{finding.fetch("signal")}` · #{finding.fetch("severity")}"
        end
      end

      lines.join("\n")
    end

    private

    def findings
      @result.fetch("findings")
    end
  end
end
