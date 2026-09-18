require "test_helper"

class RunDiff::Github::RepositoryAdmissionPolicyTest < ActiveSupport::TestCase
  test "development allows repositories when no allowlist is configured" do
    policy = RunDiff::Github::RepositoryAdmissionPolicy.new(env: {}, rails_env: "development")

    assert policy.allowed?("rundiff/rundiff")
    assert_not policy.configured?
  end

  test "configured allowlist uses exact repository full names" do
    policy = RunDiff::Github::RepositoryAdmissionPolicy.new(
      env: { "RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST" => "customer/app, customer/other" },
      rails_env: "production"
    )

    assert policy.allowed?("customer/app")
    assert policy.allowed?("customer/other")
    assert_not policy.allowed?("customer/app-fork")
    assert_not policy.allowed?("other/app")
  end

  test "production fails closed when the allowlist is absent" do
    policy = RunDiff::Github::RepositoryAdmissionPolicy.new(env: {}, rails_env: "production")

    assert_not policy.allowed?("customer/app")
  end

  test "wildcard is detectable and does not act as a pattern" do
    policy = RunDiff::Github::RepositoryAdmissionPolicy.new(
      env: { "RUNDIFF_GITHUB_REPOSITORY_ALLOWLIST" => "*" },
      rails_env: "production"
    )

    assert policy.wildcard?
    assert_not policy.allowed?("customer/app")
  end
end
