require "test_helper"
require "pathname"
require "tmpdir"

class ExecutionIdentityOutputTest < ActiveSupport::TestCase
  test "disabled identity leaves local output behavior unchanged" do
    identity = RunDiff::Subject::ExecutionIdentity.new

    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("capture.json")
      identity.prepare_output(path)

      assert_not path.exist?

      path.write("local")
      identity.seal_output(path)

      assert_equal "local", path.read
    end
  end
end
