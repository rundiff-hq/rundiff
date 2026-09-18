class RunDiffEvidenceEvent < ApplicationRecord
  validates :execution_id, :signal, :producer_kind, presence: true
end
