module RunDiff
  class ExecutionContext
    def initialize(app)
      @app = app
    end

    def call(env)
      Current.set(
        rundiff_execution_id: env["HTTP_X_RUNDIFF_EXECUTION_ID"],
        rundiff_run_id: env["HTTP_X_RUNDIFF_RUN_ID"],
        rundiff_subject: env["HTTP_X_RUNDIFF_SUBJECT"]
      ) do
        status, headers, body = @app.call(env)
        headers["X-RunDiff-Execution-Id"] ||= Current.rundiff_execution_id if Current.rundiff_execution_id
        [ status, headers, body ]
      end
    end
  end
end
