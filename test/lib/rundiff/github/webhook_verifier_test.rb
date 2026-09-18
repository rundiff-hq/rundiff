require "test_helper"

class RunDiffGithubWebhookVerifierTest < ActiveSupport::TestCase
  test "accepts a valid GitHub sha256 signature" do
    payload = '{"zen":"Keep it logically awesome."}'
    secret = "development-secret"
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, payload)}"

    assert RunDiff::Github::WebhookVerifier.new.valid?(payload:, signature:, secret:)
  end

  test "rejects an invalid signature" do
    refute RunDiff::Github::WebhookVerifier.new.valid?(
      payload: "{}",
      signature: "sha256=wrong",
      secret: "development-secret"
    )
  end
end
