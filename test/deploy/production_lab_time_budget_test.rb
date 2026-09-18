require "test_helper"
require "yaml"

class ProductionLabTimeBudgetTest < ActiveSupport::TestCase
  COMPOSE = Rails.root.join("lab/production/docker-compose.yml")
  FINALIZATION_BUDGET_SECONDS = 30
  MAX_STUCK_REMOTE_WAIT_SECONDS = 120

  test "orders remote timeout, finalization, driver wait, and durable lease" do
    compose = YAML.safe_load(COMPOSE.read, aliases: true)
    budget = compose.fetch("x-lab-time-budget").transform_values { |value| Integer(value) }

    remote_read = budget.fetch("remote_executor_read_seconds")
    request_lease = budget.fetch("executor_request_lease_seconds")
    driver_wait = budget.fetch("driver_wait_seconds")
    execution_lease = budget.fetch("execution_lease_seconds")
    heartbeat = budget.fetch("heartbeat_seconds")

    assert_operator remote_read, :<=, MAX_STUCK_REMOTE_WAIT_SECONDS
    assert_operator remote_read, :<, request_lease
    assert_operator remote_read + FINALIZATION_BUDGET_SECONDS, :<=, driver_wait
    assert_operator driver_wait, :<, execution_lease
    assert_operator heartbeat, :<, remote_read
    assert_operator heartbeat * 3, :<=, execution_lease
  end

  test "wires the declared budget into the correct lab roles" do
    compose = YAML.safe_load(COMPOSE.read, aliases: true)
    services = compose.fetch("services")
    control = services.fetch("control-plane").fetch("environment")
    executor = services.fetch("executor").fetch("environment")
    driver = services.fetch("driver").fetch("environment")
    budget = compose.fetch("x-lab-time-budget")

    assert_equal budget.fetch("remote_executor_read_seconds"),
      control.fetch("RUNDIFF_REMOTE_EXECUTOR_READ_TIMEOUT_SECONDS")
    assert_equal budget.fetch("execution_lease_seconds"),
      control.fetch("RUNDIFF_EXECUTION_LEASE_SECONDS")
    assert_equal budget.fetch("heartbeat_seconds"),
      control.fetch("RUNDIFF_EXECUTION_HEARTBEAT_INTERVAL_SECONDS")
    assert_equal budget.fetch("executor_request_lease_seconds"),
      executor.fetch("RUNDIFF_EXECUTOR_SERVICE_REQUEST_LEASE_SECONDS")
    assert_equal budget.fetch("driver_wait_seconds"),
      driver.fetch("RUNDIFF_LAB_TIMEOUT_SECONDS")
  end
end
