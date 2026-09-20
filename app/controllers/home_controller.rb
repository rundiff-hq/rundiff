class HomeController < ApplicationController
  def index
    result = RunDiff::BehavioralDiff.call(
      baseline: { duration_ms: 820, sql_queries: 14, background_jobs: 1, emails: 1, http_requests: 11, errors: 0 },
      candidate: { duration_ms: 1460, sql_queries: 47, background_jobs: 3, emails: 2, http_requests: 11, errors: 0 }
    )

    onboarding_cta = if RunDiff::Runtime::Role.from_env.control_plane?
      <<~HTML
        <div style="display:flex;gap:12px;flex-wrap:wrap;margin:32px 0">
          <a href="#{onboarding_path}" style="display:inline-block;background:#161616;color:white;text-decoration:none;font-weight:700;padding:14px 20px;border-radius:10px">
            Run your first diff
          </a>
          <a href="#sample-diff" style="display:inline-block;border:1px solid #bbb;color:#161616;text-decoration:none;font-weight:700;padding:14px 20px;border-radius:10px">
            See a sample diff
          </a>
        </div>
      HTML
    else
      ""
    end

    render html: <<~HTML.html_safe
      <main style="font-family:system-ui;max-width:960px;margin:64px auto;padding:0 24px">
        <p style="text-transform:uppercase;letter-spacing:.12em;opacity:.55">You diff your code. Now diff what it does.</p>
        <h1 style="font-size:64px;line-height:1;margin:12px 0 24px">Know what changed<br>before you merge.</h1>
        <p style="font-size:20px;line-height:1.5;opacity:.8">RunDiff runs your baseline and candidate through the same scenario, compares their runtime behavior, and surfaces meaningful changes directly in your pull request.</p>
        <p style="font-size:16px;opacity:.58">Observability tells you after deploy. RunDiff tells you before merge.</p>
        #{onboarding_cta}
        <pre id="sample-diff" style="padding:24px;border:1px solid #999;border-radius:16px;overflow:auto">#{ERB::Util.html_escape(JSON.pretty_generate(result))}</pre>
      </main>
    HTML
  end
end
