require "test_helper"
require "base64"
require "json"
require "tmpdir"

class RunDiffGithubAppAuthenticationTest < ActiveSupport::TestCase
  class FakeAuthentication < RunDiff::Github::AppAuthentication
    attr_reader :calls

    def initialize(response:, **attributes)
      @response = response
      @calls = []
      super(**attributes)
    end

    private

    def request(method, path, authorization:, body: {})
      @calls << { method:, path:, authorization:, body: }
      @response
    end
  end

  test "reads authenticated App metadata and webhook configuration with App JWT" do
    rsa = OpenSSL::PKey::RSA.generate(2048)

    Dir.mktmpdir do |directory|
      key_path = File.join(directory, "app.pem")
      File.write(key_path, rsa.to_pem)

      authentication = FakeAuthentication.new(
        response: { "slug" => "rundiff" },
        app_id: 4_831_516,
        private_key_path: key_path
      )

      assert_equal "rundiff", authentication.app.fetch("slug")
      assert_equal "rundiff", authentication.webhook_configuration.fetch("slug")

      assert_equal :get, authentication.calls.fetch(0).fetch(:method)
      assert_equal "/app", authentication.calls.fetch(0).fetch(:path)
      assert_equal :get, authentication.calls.fetch(1).fetch(:method)
      assert_equal "/app/hook/config", authentication.calls.fetch(1).fetch(:path)
      assert_match(/\ABearer /, authentication.calls.fetch(0).fetch(:authorization))
    end
  end

  test "can sign App JWT from private key PEM environment value" do
    rsa = OpenSSL::PKey::RSA.generate(2048)

    authentication = FakeAuthentication.new(
      response: { "slug" => "rundiff" },
      app_id: 4_831_516,
      private_key_pem: rsa.to_pem
    )

    assert_equal "rundiff", authentication.app.fetch("slug")
    assert_match(/\ABearer /, authentication.calls.fetch(0).fetch(:authorization))
  end

  test "lists recent App webhook deliveries with App JWT" do
    rsa = OpenSSL::PKey::RSA.generate(2048)

    Dir.mktmpdir do |directory|
      key_path = File.join(directory, "app.pem")
      File.write(key_path, rsa.to_pem)

      authentication = FakeAuthentication.new(
        response: [
          {
            "id" => 123,
            "guid" => "0b989ba4-242f-11e5-81e1-c7b6966d2516",
            "event" => "pull_request",
            "action" => "opened"
          }
        ],
        app_id: 4_831_516,
        private_key_path: key_path
      )

      deliveries = authentication.webhook_deliveries

      assert_equal 1, deliveries.length
      call = authentication.calls.fetch(0)
      assert_equal :get, call.fetch(:method)
      assert_equal "/app/hook/deliveries?per_page=100", call.fetch(:path)
      assert_match(/\ABearer /, call.fetch(:authorization))
    end
  end

  test "resolves the App installation for a repository" do
    rsa = OpenSSL::PKey::RSA.generate(2048)

    Dir.mktmpdir do |directory|
      key_path = File.join(directory, "app.pem")
      File.write(key_path, rsa.to_pem)

      authentication = FakeAuthentication.new(
        response: { "id" => 158_885_061, "app_slug" => "rundiff" },
        app_id: 4_831_516,
        private_key_path: key_path
      )

      installation = authentication.repository_installation(repository: "rundiff-hq/customer-rails-sandbox")

      assert_equal 158_885_061, installation.fetch("id")
      call = authentication.calls.fetch(0)
      assert_equal :get, call.fetch(:method)
      assert_equal "/repos/rundiff-hq/customer-rails-sandbox/installation", call.fetch(:path)
      assert_match(/\ABearer /, call.fetch(:authorization))
    end
  end

  test "rejects malformed repository names before App API access" do
    rsa = OpenSSL::PKey::RSA.generate(2048)

    Dir.mktmpdir do |directory|
      key_path = File.join(directory, "app.pem")
      File.write(key_path, rsa.to_pem)

      authentication = FakeAuthentication.new(
        response: {},
        app_id: 4_831_516,
        private_key_path: key_path
      )

      error = assert_raises(ArgumentError) do
        authentication.repository_installation(repository: "not-a-repository")
      end

      assert_includes error.message, "owner/name"
      assert_empty authentication.calls
    end
  end

  test "signs an app JWT and exchanges it for an installation token" do
    now = Time.utc(2026, 9, 4, 17, 30, 0)
    rsa = OpenSSL::PKey::RSA.generate(2048)

    Dir.mktmpdir do |directory|
      key_path = File.join(directory, "app.pem")
      File.write(key_path, rsa.to_pem)

      authentication = FakeAuthentication.new(
        response: { "token" => "installation-token", "expires_at" => "2026-09-04T18:30:00Z" },
        app_id: 4_831_516,
        private_key_path: key_path,
        clock: -> { now }
      )

      token = authentication.installation_token(installation_id: 158_885_061)

      assert_equal "installation-token", token.value
      assert_equal Time.utc(2026, 9, 4, 18, 30, 0), token.expires_at

      call = authentication.calls.fetch(0)
      assert_equal :post, call.fetch(:method)
      assert_equal "/app/installations/158885061/access_tokens", call.fetch(:path)
      assert_empty call.fetch(:body)

      jwt = call.fetch(:authorization).delete_prefix("Bearer ")
      encoded_header, encoded_payload, encoded_signature = jwt.split(".")
      header = JSON.parse(decode_base64url(encoded_header))
      payload = JSON.parse(decode_base64url(encoded_payload))
      signature = decode_base64url(encoded_signature)

      assert_equal({ "alg" => "RS256", "typ" => "JWT" }, header)
      assert_equal "4831516", payload.fetch("iss")
      assert_equal now.to_i - 60, payload.fetch("iat")
      assert_equal now.to_i + 540, payload.fetch("exp")
      assert rsa.public_key.verify(OpenSSL::Digest::SHA256.new, signature, "#{encoded_header}.#{encoded_payload}")
    end
  end

  test "narrows an installation token to one repository and contents read" do
    rsa = OpenSSL::PKey::RSA.generate(2048)

    Dir.mktmpdir do |directory|
      key_path = File.join(directory, "app.pem")
      File.write(key_path, rsa.to_pem)

      authentication = FakeAuthentication.new(
        response: { "token" => "scoped-token", "expires_at" => "2026-09-04T18:30:00Z" },
        app_id: 4_831_516,
        private_key_path: key_path
      )

      authentication.installation_token(
        installation_id: 159_078_958,
        repositories: [ "rundiff" ],
        permissions: { contents: "read" }
      )

      assert_equal(
        {
          repositories: [ "rundiff" ],
          permissions: { contents: "read" }
        },
        authentication.calls.fetch(0).fetch(:body)
      )
    end
  end

  test "syncs the app webhook configuration with the current secret" do
    now = Time.utc(2026, 9, 4, 17, 30, 0)
    rsa = OpenSSL::PKey::RSA.generate(2048)

    Dir.mktmpdir do |directory|
      key_path = File.join(directory, "app.pem")
      File.write(key_path, rsa.to_pem)

      authentication = FakeAuthentication.new(
        response: {
          "url" => "https://github-dev.flowato.dev/github/webhooks",
          "content_type" => "json",
          "insecure_ssl" => "0"
        },
        app_id: 4_831_516,
        private_key_path: key_path,
        clock: -> { now }
      )

      result = authentication.sync_webhook!(
        url: "https://github-dev.flowato.dev/github/webhooks",
        secret: "current-secret"
      )

      assert_equal "https://github-dev.flowato.dev/github/webhooks", result.fetch("url")

      call = authentication.calls.fetch(0)
      assert_equal :patch, call.fetch(:method)
      assert_equal "/app/hook/config", call.fetch(:path)
      assert_equal(
        {
          url: "https://github-dev.flowato.dev/github/webhooks",
          content_type: "json",
          secret: "current-secret",
          insecure_ssl: "0"
        },
        call.fetch(:body)
      )
    end
  end

  private

  def decode_base64url(value)
    padding = "=" * ((4 - value.length % 4) % 4)
    Base64.urlsafe_decode64("#{value}#{padding}")
  end
end
