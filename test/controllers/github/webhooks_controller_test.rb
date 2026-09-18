require "test_helper"

class GithubWebhooksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
  end

  test "persists but ignores a non-execution webhook" do
    with_webhook_secret do
      payload = JSON.generate(
        "action" => "created",
        "installation" => { "id" => 123 }
      )

      post_signed_webhook(payload:, event: "installation", delivery: "delivery-installation-1")

      assert_response :accepted
      body = response.parsed_body
      assert_equal true, body.fetch("ok")
      assert_equal "installation", body.fetch("event")
      assert_equal 123, body.fetch("installation_id")
      assert_equal "ignored", body.fetch("delivery_status")

      delivery = GithubWebhookDelivery.find_by!(delivery_id: "delivery-installation-1")
      assert_equal "installation", delivery.event
      assert_equal 123, delivery.installation_id
      assert_equal "ignored", delivery.status
      assert_equal "event_not_execution_trigger", delivery.failure
    end
  end

  test "persists and enqueues a pull request delivery once" do
    with_webhook_secret do
      payload = JSON.generate(
        "action" => "synchronize",
        "number" => 19,
        "installation" => { "id" => 158_885_061 },
        "repository" => { "full_name" => "rundiff/rundiff" },
        "pull_request" => {
          "base" => { "sha" => "base-sha" },
          "head" => { "sha" => "head-sha" }
        }
      )

      assert_enqueued_with(job: GithubPullRequestWebhookJob) do
        post_signed_webhook(payload:, event: "pull_request", delivery: "delivery-pr-1")
      end

      assert_response :accepted
      delivery = GithubWebhookDelivery.find_by!(delivery_id: "delivery-pr-1")
      assert_equal "rundiff/rundiff", delivery.repository
      assert_equal 19, delivery.pull_request_number
      assert_equal "base-sha", delivery.base_sha
      assert_equal "head-sha", delivery.head_sha

      assert_no_enqueued_jobs do
        post_signed_webhook(payload:, event: "pull_request", delivery: "delivery-pr-1")
      end
    end
  end

  test "persists but does not enqueue a pull request outside the configured allowlist" do
    with_webhook_secret do
      with_repository_allowlist("approved/customer-app") do
        payload = JSON.generate(
          "action" => "synchronize",
          "number" => 20,
          "installation" => { "id" => 158_885_061 },
          "repository" => { "full_name" => "unapproved/customer-app" },
          "pull_request" => {
            "base" => { "sha" => "base-sha" },
            "head" => { "sha" => "head-sha" }
          }
        )

        assert_no_enqueued_jobs do
          post_signed_webhook(payload:, event: "pull_request", delivery: "delivery-pr-denied")
          post_signed_webhook(payload:, event: "pull_request", delivery: "delivery-pr-denied")
        end

        assert_response :accepted
        delivery = GithubWebhookDelivery.find_by!(delivery_id: "delivery-pr-denied")
        assert_equal "ignored", delivery.status
        assert_equal "repository_not_allowed", delivery.failure
      end
    end
  end

  test "configured allowlist permits an exact pull request repository" do
    with_webhook_secret do
      with_repository_allowlist("approved/customer-app") do
        payload = JSON.generate(
          "action" => "synchronize",
          "number" => 21,
          "installation" => { "id" => 158_885_061 },
          "repository" => { "full_name" => "approved/customer-app" },
          "pull_request" => {
            "base" => { "sha" => "base-sha" },
            "head" => { "sha" => "head-sha" }
          }
        )

        assert_enqueued_with(job: GithubPullRequestWebhookJob) do
          post_signed_webhook(payload:, event: "pull_request", delivery: "delivery-pr-allowed")
        end

        delivery = GithubWebhookDelivery.find_by!(delivery_id: "delivery-pr-allowed")
        assert_equal "accepted", delivery.status
      end
    end
  end

  test "settles completed check runs as ignored" do
    with_webhook_secret do
      payload = JSON.generate(
        "action" => "completed",
        "installation" => { "id" => 158_885_061 },
        "repository" => { "full_name" => "rundiff/rundiff" }
      )

      post_signed_webhook(payload:, event: "check_run", delivery: "delivery-check-run-completed")

      assert_response :accepted
      delivery = GithubWebhookDelivery.find_by!(delivery_id: "delivery-check-run-completed")
      assert_equal "ignored", delivery.status
      assert_equal "event_not_execution_trigger", delivery.failure
    end
  end

  test "persists and enqueues rerequested check runs" do
    with_webhook_secret do
      payload = JSON.generate(
        "action" => "rerequested",
        "installation" => { "id" => 158_885_061 },
        "repository" => { "full_name" => "rundiff/rundiff" },
        "check_run" => {
          "head_sha" => "head-sha",
          "external_id" => "github-execution-123"
        }
      )

      assert_enqueued_with(job: GithubCheckRunRerequestJob) do
        post_signed_webhook(payload:, event: "check_run", delivery: "delivery-check-run-rerequested")
      end

      assert_response :accepted
      delivery = GithubWebhookDelivery.find_by!(delivery_id: "delivery-check-run-rerequested")
      assert_equal "accepted", delivery.status
      assert_equal "head-sha", delivery.head_sha
      assert_equal "github-execution-123", delivery.external_id
    end
  end

  test "does not enqueue a rerequested check run outside the configured allowlist" do
    with_webhook_secret do
      with_repository_allowlist("approved/customer-app") do
        payload = JSON.generate(
          "action" => "rerequested",
          "installation" => { "id" => 158_885_061 },
          "repository" => { "full_name" => "unapproved/customer-app" },
          "check_run" => {
            "head_sha" => "head-sha",
            "external_id" => "github-execution-denied"
          }
        )

        assert_no_enqueued_jobs do
          post_signed_webhook(payload:, event: "check_run", delivery: "delivery-check-run-denied")
        end

        delivery = GithubWebhookDelivery.find_by!(delivery_id: "delivery-check-run-denied")
        assert_equal "ignored", delivery.status
        assert_equal "repository_not_allowed", delivery.failure
      end
    end
  end

  test "rejects an unsigned webhook" do
    with_webhook_secret do
      post github_webhooks_url,
        params: "{}",
        headers: {
          "CONTENT_TYPE" => "application/json",
          "X-GitHub-Event" => "ping",
          "X-GitHub-Delivery" => "delivery-unsigned"
        }

      assert_response :unauthorized
    end
  end

  private

  def with_webhook_secret
    previous_secret = ENV["RUNDIFF_GITHUB_WEBHOOK_SECRET"]
    ENV["RUNDIFF_GITHUB_WEBHOOK_SECRET"] = "development-secret"
    yield
  ensure
    ENV["RUNDIFF_GITHUB_WEBHOOK_SECRET"] = previous_secret
  end

  def with_repository_allowlist(value)
    previous_allowlist = ENV["RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST"]
    ENV["RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST"] = value
    yield
  ensure
    ENV["RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST"] = previous_allowlist
  end

  def post_signed_webhook(payload:, event:, delivery:)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("RUNDIFF_GITHUB_WEBHOOK_SECRET"), payload)}"

    post github_webhooks_url,
      params: payload,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "X-Hub-Signature-256" => signature,
        "X-GitHub-Event" => event,
        "X-GitHub-Delivery" => delivery
      }
  end
end
