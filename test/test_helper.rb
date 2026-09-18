ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ClockAuthorityTestHelper
  def with_database_clock(now)
    singleton = RunDiff::ClockAuthority.singleton_class
    original = RunDiff::ClockAuthority.method(:database_now)
    singleton.send(:define_method, :database_now) { |connection: ApplicationRecord.connection| now }
    yield
  ensure
    singleton.send(:define_method, :database_now, original) if singleton && original
  end
end

ActiveSupport::TestCase.include ClockAuthorityTestHelper
