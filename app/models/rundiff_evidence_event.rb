class RunDiffEvidenceEvent < ApplicationRecord
  self.table_name = "rundiff_evidence_events"
  validates :execution_id, :signal, :producer_kind, presence: true
end
