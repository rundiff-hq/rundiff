require "active_support/security_utils"
require "openssl"

module RunDiff
  module Github
    class WebhookVerifier
      def valid?(payload:, signature:, secret:)
        return false if signature.to_s.empty? || secret.to_s.empty?

        expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, payload)}"
        ActiveSupport::SecurityUtils.secure_compare(expected, signature)
      end
    end
  end
end
