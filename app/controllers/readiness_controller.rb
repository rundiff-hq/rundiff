class ReadinessController < ApplicationController
  def show
    result = RunDiff::Runtime::Readiness.new.call
    payload = result.to_h
    payload["queue"] = RunDiff::Runtime::QueueHealth.new.call if result.role == "control_plane"

    render json: payload, status: result.ready? ? :ok : :service_unavailable
  end
end
