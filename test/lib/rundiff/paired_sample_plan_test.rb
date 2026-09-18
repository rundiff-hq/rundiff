require "test_helper"

class RunDiffPairedSamplePlanTest < ActiveSupport::TestCase
  test "alternates which side runs first while keeping each pair adjacent" do
    steps = RunDiff::PairedSamplePlan.call(sample_count: 3)

    assert_equal(
      [
        [ 1, "base", 1 ],
        [ 1, "candidate", 2 ],
        [ 2, "candidate", 1 ],
        [ 2, "base", 2 ],
        [ 3, "base", 1 ],
        [ 3, "candidate", 2 ]
      ],
      steps.map { |step| [ step.sample_index, step.role, step.position ] }
    )
  end

  test "creates exactly two captures per sample index" do
    steps = RunDiff::PairedSamplePlan.call(sample_count: 5)

    assert_equal 10, steps.length
    assert_equal(
      { 1 => 2, 2 => 2, 3 => 2, 4 => 2, 5 => 2 },
      steps.group_by(&:sample_index).transform_values(&:length)
    )
    assert steps.group_by(&:sample_index).values.all? do |pair|
      pair.map(&:role).sort == %w[base candidate]
    end
  end

  test "rejects invalid sample counts" do
    [ 0, -1, "not-a-number", nil ].each do |value|
      assert_raises(RunDiff::PairedSamplePlan::Error) do
        RunDiff::PairedSamplePlan.call(sample_count: value)
      end
    end
  end
end
