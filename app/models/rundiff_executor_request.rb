require "digest"
require "json"
require "securerandom"

class RunDiffExecutorRequest < ApplicationRecord
  Acquisition = Data.define(:state, :record, :claim_token)
  Cancellation = Data.define(:state, :record)
  DigestMismatch = Class.new(StandardError)

  STATUSES = %w[processing completed cancelled].freeze
  DEFAULT_LEASE_SECONDS = 2_400
  CANCELLED_BEFORE_REQUEST_DIGEST = "cancelled-before-request".freeze

  validates :idempotency_key, :request_digest, :status, presence: true
  validates :idempotency_key, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def self.acquire!(idempotency_key:, request_payload:, now: nil, lease_seconds: DEFAULT_LEASE_SECONDS)
    lease_seconds = Integer(lease_seconds)
    raise ArgumentError, "Executor request lease must be positive" unless lease_seconds.positive?

    request_digest = digest_for(request_payload)

    loop do
      current_now = authoritative_now(now)

      if (record = find_by(idempotency_key:))
        return Acquisition.new(state: :cancelled, record:, claim_token: nil) if record.status == "cancelled"
        raise DigestMismatch, "Idempotency key was reused for a different executor request" if record.request_digest != request_digest
        return Acquisition.new(state: :completed, record:, claim_token: nil) if record.status == "completed"

        if record.lease_expires_at && record.lease_expires_at > current_now
          return Acquisition.new(state: :in_progress, record:, claim_token: nil)
        end

        claim_token = SecureRandom.uuid
        claimed = where(id: record.id, status: "processing")
          .where("lease_expires_at IS NULL OR lease_expires_at <= ?", current_now)
          .update_all(
            claim_token:,
            started_at: current_now,
            lease_expires_at: current_now + lease_seconds.seconds,
            updated_at: current_now
          )

        if claimed == 1
          record.reload
          return Acquisition.new(state: :execute, record:, claim_token:)
        end

        next
      end

      claim_token = SecureRandom.uuid
      begin
        record = create!(
          idempotency_key:,
          request_digest:,
          status: "processing",
          claim_token:,
          request_payload:,
          result: {},
          started_at: current_now,
          lease_expires_at: current_now + lease_seconds.seconds
        )
        return Acquisition.new(state: :execute, record:, claim_token:)
      rescue ActiveRecord::RecordNotUnique
        next
      end
    end
  end

  def self.cancel!(idempotency_key:, reason: "cancelled", now: nil)
    loop do
      current_now = authoritative_now(now)

      if (record = find_by(idempotency_key:))
        return Cancellation.new(state: :completed, record:) if record.status == "completed"
        return Cancellation.new(state: :cancelled, record:) if record.status == "cancelled"

        cancelled = where(id: record.id, status: "processing").update_all(
          status: "cancelled",
          claim_token: nil,
          lease_expires_at: nil,
          cancellation_reason: reason.to_s,
          cancelled_at: current_now,
          finished_at: current_now,
          updated_at: current_now
        )
        next unless cancelled == 1

        record.reload
        return Cancellation.new(state: :cancelled, record:)
      end

      begin
        record = create!(
          idempotency_key:,
          request_digest: CANCELLED_BEFORE_REQUEST_DIGEST,
          status: "cancelled",
          claim_token: nil,
          request_payload: {},
          result: {},
          cancellation_reason: reason.to_s,
          cancelled_at: current_now,
          finished_at: current_now,
          lease_expires_at: nil
        )
        return Cancellation.new(state: :cancelled, record:)
      rescue ActiveRecord::RecordNotUnique
        next
      end
    end
  end

  def complete_claim!(claim_token:, result_payload:, now: nil)
    now = self.class.authoritative_now(now)
    completed = self.class.where(id:, status: "processing", claim_token:)
      .where("lease_expires_at > ?", now)
      .update_all(
        status: "completed",
        result: result_payload,
        claim_token: nil,
        lease_expires_at: nil,
        finished_at: now,
        updated_at: now
      )

    reload if completed == 1
    completed == 1
  end

  def self.digest_for(payload)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))
  end

  def self.authoritative_now(explicit_now)
    explicit_now || RunDiff::ClockAuthority.database_now(connection: connection)
  end

  def self.canonicalize(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested), output|
        output[key.to_s] = canonicalize(nested)
      end.sort.to_h
    when Array
      value.map { |nested| canonicalize(nested) }
    else
      value
    end
  end
  private_class_method :canonicalize
end
