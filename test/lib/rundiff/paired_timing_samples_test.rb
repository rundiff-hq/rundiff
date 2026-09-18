require "test_helper"

class RunDiffPairedTimingSamplesTest < ActiveSupport::TestCase
  test "turns a PR 102 style one-sample outlier into a small robust median delta" do
    result = RunDiff::PairedTimingSamples.call(
      baseline_samples: [118.7, 152.5, 151.0],
      candidate_samples: [159.6, 158.1, 155.0]
    )

    assert_equal 3, result.fetch("sample_count")
    assert_equal "sampled", result.fetch("sample_quality")
    assert_equal 151.0, result.fetch("baseline_median")
    assert_equal 158.1, result.fetch("candidate_median")
    assert_equal 5.6, result.fetch("median_delta")
    assert_equal 3.709, result.fetch("delta_percent")
    assert_equal 1.6, result.fetch("delta_mad")
  end

  test "preserves a repeatable paired regression" do
    result = RunDiff::PairedTimingSamples.call(
      baseline_samples: [100.0, 102.0, 101.0],
      candidate_samples: [140.0, 142.0, 141.0]
    )

    assert_equal "sampled", result.fetch("sample_quality")
    assert_equal 101.0, result.fetch("baseline_median")
    assert_equal 141.0, result.fetch("candidate_median")
    assert_equal 40.0, result.fetch("median_delta")
    assert_equal 39.604, result.fetch("delta_percent")
    assert_equal 0.0, result.fetch("delta_mad")
  end

  test "marks fewer than the minimum paired samples as insufficient" do
    result = RunDiff::PairedTimingSamples.call(
      baseline_samples: [100.0, 101.0],
      candidate_samples: [110.0, 111.0]
    )

    assert_equal 2, result.fetch("sample_count")
    assert_equal "insufficient_samples", result.fetch("sample_quality")
  end

  test "uses the midpoint average for even sample counts" do
    result = RunDiff::PairedTimingSamples.call(
      baseline_samples: [100.0, 102.0, 104.0, 106.0],
      candidate_samples: [110.0, 112.0, 114.0, 116.0],
      min_samples: 4
    )

    assert_equal 103.0, result.fetch("baseline_median")
    assert_equal 113.0, result.fetch("candidate_median")
    assert_equal 10.0, result.fetch("median_delta")
    assert_equal 9.709, result.fetch("delta_percent")
  end

  test "returns nil percentage when the robust baseline is zero" do
    result = RunDiff::PairedTimingSamples.call(
      baseline_samples: [0.0, 0.0, 0.0],
      candidate_samples: [1.0, 1.0, 1.0]
    )

    assert_nil result.fetch("delta_percent")
    assert_equal 1.0, result.fetch("median_delta")
  end

  test "rejects unpaired sample counts" do
    error = assert_raises(RunDiff::PairedTimingSamples::Error) do
      RunDiff::PairedTimingSamples.call(
        baseline_samples: [100.0, 101.0, 102.0],
        candidate_samples: [110.0, 111.0]
      )
    end

    assert_includes error.message, "equal lengths"
  end

  test "rejects non-numeric and non-finite samples" do
    error = assert_raises(RunDiff::PairedTimingSamples::Error) do
      RunDiff::PairedTimingSamples.call(
        baseline_samples: [100.0, "not-a-number", 102.0],
        candidate_samples: [110.0, 111.0, 112.0]
      )
    end
    assert_includes error.message, "must be numeric"

    error = assert_raises(RunDiff::PairedTimingSamples::Error) do
      RunDiff::PairedTimingSamples.call(
        baseline_samples: [100.0, Float::INFINITY, 102.0],
        candidate_samples: [110.0, 111.0, 112.0]
      )
    end
    assert_includes error.message, "must be finite"
  end

  test "requires at least one paired sample and a positive minimum" do
    assert_raises(RunDiff::PairedTimingSamples::Error) do
      RunDiff::PairedTimingSamples.call(
        baseline_samples: [],
        candidate_samples: []
      )
    end

    assert_raises(RunDiff::PairedTimingSamples::Error) do
      RunDiff::PairedTimingSamples.call(
        baseline_samples: [1.0],
        candidate_samples: [1.0],
        min_samples: 0
      )
    end
  end
end
