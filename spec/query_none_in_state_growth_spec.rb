require "spec_helper"
require_relative "support/inline_bluebook_boot"

# none_in_state on an entity query, including when the reference points at no record.
# meta_validation is off so the comparator/interpreter pair is tested, not grammar admission.
RSpec.describe "none_in_state, a cross-aggregate anti-join" do
  include InlineBluebookBoot

  NONE_IN_STATE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "AntiJoinGrowth" do
      aggregate "Claim" do
        identified_by :id

        value_object "ClaimId" do
          attribute :value, String
        end

        value_object "ClaimState" do
          attribute :value, String, default: "held"
        end

        attribute :id,    ClaimId
        attribute :state, ClaimState

        command "File" do
          attribute :id, ClaimId
          emits "Filed"
        end

        command "Release" do
          reference_to Claim
          sets :state, to: { value: "released" }
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

  def boot_anti_join
    boot(NONE_IN_STATE_SOURCE, "AntiJoinGrowth") do
      AntiJoinGrowth::Claim.persisted_by("Memory")
      AntiJoinGrowth::Board.persisted_by("Memory")
    end
  end

  # Two claims, one released; and a board holding an assignment for each of them and for a claim
  # that does not exist.
  def seed_claims_and_board(runtime)
    runtime.dispatch_flat("AntiJoinGrowth::Claim.File", id: { value: "c1" }) # stays "held"
    runtime.dispatch_flat("AntiJoinGrowth::Claim.File", id: { value: "c2" })
    runtime.dispatch_flat("AntiJoinGrowth::Claim.Release", id: "c2")         # leaves "held"
    runtime.dispatch_flat("AntiJoinGrowth::Board.Open", id: { value: "b1" })
    %w[c1 c2 nonexistent].each do |claim|
      runtime.dispatch_flat("AntiJoinGrowth::Board.Assign", id: "b1", claim_id: claim)
    end
  end

  it "excludes an assignment whose claim IS in the named state, and keeps the rest" do
    runtime = boot_anti_join
    seed_claims_and_board(runtime)
    rows = runtime.query("AntiJoinGrowth::Board.Assignment.Unclaimed")

    expect(rows.map { |row| row[:claim_id] }).to contain_exactly("c2", "nonexistent")
  end
end
