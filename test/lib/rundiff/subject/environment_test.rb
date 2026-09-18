require "test_helper"

class RunDiffSubjectEnvironmentTest < ActiveSupport::TestCase
  class ExampleEnvironment < RunDiff::Subject::Environment
    CAPABILITIES = %w[
      framework.rails
      persistence.sqlite
      telemetry.subject_owned_rails
      state.isolated_comparable
    ].freeze

    def capabilities
      CAPABILITIES
    end
  end

  test "base environment declares no capabilities" do
    environment = RunDiff::Subject::Environment.new

    assert_empty environment.capabilities
    assert_not environment.capability?("persistence.postgresql")
    assert_empty environment.capabilities_for(:persistence)
  end

  test "queries namespaced capabilities without exposing them to executor contracts" do
    environment = ExampleEnvironment.new

    assert environment.capability?("framework.rails")
    assert environment.capability?(:"state.isolated_comparable")
    assert_equal [ "sqlite" ], environment.capabilities_for(:persistence)
    assert_equal [ "subject_owned_rails" ], environment.capabilities_for(:telemetry)
    assert_not environment.capability?("persistence.postgresql")
  end
end
