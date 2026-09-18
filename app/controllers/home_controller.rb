class HomeController < ApplicationController
  def index
    result = RunDiff::BehavioralDiff.call(
      baseline: { duration_ms: 820, sql_queries: 14, background_jobs: 1, emails: 1, http_requests: 11, errors: 0 },
      candidate: { duration_ms: 1460, sql_queries: 47, background_jobs: 3, emails: 2, http_requests: 11, errors: 0 }
    )

    onboarding_cta = if RunDiff::Runtime::Role.from_env.control_plane?
      <<~HTML
        <p style="margin:32px 0">
          <a href="#{onboarding_path}" style="display:inline-block;background:#161616;color:white;text-decoration:none;font-weight:700;padding:14px 20px;border-radius:10px">
            Install RunDiff on a Rails repo
          </a>
        </p>
      HTML
    else
      ""
    end

    render html: <<~HTML.html_safe
      <main style="font-family:system-ui;max-width:960px;margin:64px auto;padding:0 24px">
        <p style="text-transform:uppercase;letter-spacing:.12em;opacity:.55">RunDiff behavioral diff</p>
        <h1 style="font-size:64px;line-height:1;margin:12px 0 24px">Tests passed.<br>Behavior changed.</h1>
        <p style="font-size:20px;opacity:.8">Bootstrap result: #{result.fetch("findings").size} behavioral regressions detected while the functional scenario still passes.</p>
        #{onboarding_cta}
        <pre style="padding:24px;border:1px solid #999;border-radius:16px;overflow:auto">#{ERB::Util.html_escape(JSON.pretty_generate(result))}</pre>
      </main>
    HTML
  end
end
