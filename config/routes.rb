Rails.application.routes.draw do
  runtime_role = RunDiff::Runtime::Role.from_env

  root "home#index"
  get "up" => "rails/health#show", as: :rails_health_check
  get "ready" => "readiness#show", as: :readiness_check

  if runtime_role.control_plane?
    get "/onboarding" => "onboarding#index", as: :onboarding
    get "/github/app/register" => "github/app_manifests#new", as: :github_app_register
    get "/github/app/manifest/callback" => "github/app_manifests#callback", as: :github_app_manifest_callback
    post "/github/webhooks" => "github/webhooks#create", as: :github_webhooks

    post "/v1/execution-bridges/github-actions/claim" => "execution_bridges/github_actions#claim",
      as: :github_actions_execution_bridge_claim
    post "/v1/execution-bridges/github-actions/executions/:execution_id/attempts/:attempt_number/result" =>
      "execution_bridges/github_actions#result",
      as: :github_actions_execution_bridge_result
  end

  if runtime_role.executor_service?
    post "/v1/executions" => "executor/executions#create", as: :executor_service_executions
    post "/v1/executions/:execution_id/attempts/:attempt_number/cancel" => "executor/executions#cancel",
      as: :cancel_executor_service_execution
  end

  if Rails.env.development? || Rails.env.test?
    post "/__rundiff/demo/behavior" => "demo/behavior#create"
    post "/__rundiff/demo/process-proof" => "demo/process_proof#create"
  end
end
