require "spec_helper"
require_relative "support/inline_bluebook_boot"

# none_in_state against a `lifecycle :status` target, not a plain `state` attribute.
# meta_validation is off so the comparator/interpreter pair is tested, not grammar admission.
RSpec.describe "none_in_state against a lifecycle-backed target" do
  include InlineBluebookBoot

  NONE_IN_STATE_LIFECYCLE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "AntiJoinLifecycle" do
      aggregate "Claim" do
        identified_by :id

        value_object "ClaimId" do
          attribute :value, String
        end

        attribute :id, ClaimId

        lifecycle :status, default: "held" do
          transition "Release" => "released", from: "held"
        end

        command "File" do
          attribute :id, ClaimId
          emits "Filed"
        end

        command "Release" do
          reference_to Claim
          emits "Released"
        end
      end

      aggregate "Board" do
        identified_by :id

        value_object "BoardId" do
          attribute :value, String
        end

        attribute :id,          BoardId
        attribute :assignments, list_of(Assignment)

        entity "Assignment" do
          identified_by :claim_id

          attribute :claim_id, String

          query "Unclaimed" do
            where claim_id: { none_in_state: "Claim:held" }
          end
        end

        command "Open" do
          attribute :id, BoardId
          emits "Opened"
        end

        command "Assign" do
          reference_to Board
          attribute :claim_id, String
          sets :assignments, append: { claim_id: :claim_id }
          emits "Assigned"
        end
      end
    end
  BLUEBOOK

  def boot_anti_join_lifecycle
    boot(NONE_IN_STATE_LIFECYCLE_SOURCE, "AntiJoinLifecycle") do
      AntiJoinLifecycle::Claim.persisted_by("Memory")
      AntiJoinLifecycle::Board.persisted_by("Memory")
    end
  end

  def dispatch(runtime, verb, **args) = runtime.dispatch_flat("AntiJoinLifecycle::#{verb}", **args)

  # Two claims are filed and the second is released (so only c1 stays "held"); a board is then
  # assigned both claims and one that does not exist.
  def runtime_with_assigned_claims
    runtime = boot_anti_join_lifecycle
    dispatch(runtime, "Claim.File", id: { value: "c1" })  # stays "held"
    dispatch(runtime, "Claim.File", id: { value: "c2" })
    dispatch(runtime, "Claim.Release", id: "c2")          # leaves "held"
    dispatch(runtime, "Board.Open", id: { value: "b1" })
    %w[c1 c2 nonexistent].each { |claim_id| dispatch(runtime, "Board.Assign", id: "b1", claim_id: claim_id) }
    runtime
  end

  it "reads the target's own declared lifecycle field, not a hardcoded :state key" do
    rows = runtime_with_assigned_claims.query("AntiJoinLifecycle::Board.Assignment.Unclaimed")

    # The target has no `:state` attribute, only `:status` via `lifecycle`; a bare
    # `record.state[:state]` read would wrongly include c1 (still held).
    expect(rows.map { |row| row[:claim_id] }).to contain_exactly("c2", "nonexistent")
  end
end
