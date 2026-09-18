module RunDiff
  class ClockAuthority
    DATABASE_NOW_SQL = "SELECT clock_timestamp()".freeze

    def self.database_now(connection: ApplicationRecord.connection)
      value = connection.select_value(DATABASE_NOW_SQL, "RunDiff database clock")
      value = Time.zone.parse(value) if value.is_a?(String)
      value.in_time_zone
    end

    def self.monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
