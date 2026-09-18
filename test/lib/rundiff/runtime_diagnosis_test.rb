require "test_helper"

class RunDiffRuntimeDiagnosisTest < ActiveSupport::TestCase
  test "classifies meaningful low CPU ratio as wait bound" do
    result = RunDiff::RuntimeDiagnosis.call(wall_ms: 800, thread_cpu_ms: 70)

    assert_equal "wait_bound", result.fetch("classification")
    assert_equal 8.8, result.fetch("cpu_ratio_percent")
    assert_equal 800.0, result.fetch("wall_ms")
    assert_equal 70.0, result.fetch("thread_cpu_ms")
  end

  test "does not classify sub-threshold runtime samples" do
    result = RunDiff::RuntimeDiagnosis.call(wall_ms: 0.2, thread_cpu_ms: 0.2)

    assert_equal "insufficient_signal", result.fetch("classification")
    assert_equal 100.0, result.fetch("cpu_ratio_percent")
    assert_equal 0.2, result.fetch("wall_ms")
    assert_equal 0.2, result.fetch("thread_cpu_ms")
  end

  test "classifies meaningful high CPU ratio as cpu bound" do
    result = RunDiff::RuntimeDiagnosis.call(wall_ms: 100, thread_cpu_ms: 82)

    assert_equal "cpu_bound", result.fetch("classification")
    assert_equal 82.0, result.fetch("cpu_ratio_percent")
  end

  test "returns unknown when clocks are unavailable" do
    result = RunDiff::RuntimeDiagnosis.call(wall_ms: nil, thread_cpu_ms: nil)

    assert_equal "unknown", result.fetch("classification")
    assert_nil result.fetch("cpu_ratio_percent")
  end
end
