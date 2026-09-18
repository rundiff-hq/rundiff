require "test_helper"

class RunDiffClockAuthorityTest < ActiveSupport::TestCase
  test "reads wall time from PostgreSQL clock_timestamp" do
    calls = []
    connection = Object.new
    connection.define_singleton_method(:select_value) do |sql, name|
      calls << [ sql, name ]
      "2026-09-05 00:40:00+00"
    end

    assert_equal Time.zone.parse("2026-09-05 00:40:00 UTC"), RunDiff::ClockAuthority.database_now(connection:)
    assert_equal [ [ RunDiff::ClockAuthority::DATABASE_NOW_SQL, "RunDiff database clock" ] ], calls
  end

  test "monotonic clock never exposes wall-clock time" do
    first = RunDiff::ClockAuthority.monotonic_now
    second = RunDiff::ClockAuthority.monotonic_now

    assert_kind_of Numeric, first
    assert_operator second, :>=, first
  end
end
