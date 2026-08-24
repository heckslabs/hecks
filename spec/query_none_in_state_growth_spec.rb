require "spec_helper"
require "tempfile"

# Real dispatch coverage for `none_in_state` -- finding #13, a
# cross-aggregate anti-join comparator: `where field: { none_in_state:
# "Aggregate:state" }` holds when the record `field`'s value points at
# is NOT currently in that state (including when it points at no record
# at all). Exercised on an ENTITY query -- the equivalent AGGREGATE-level
# query has a separate, later-landing gap in `Ports::Query::InMemory`
# this coverage does not exercise.
#
# `meta_validation: false` -- the self-hosted grammar's own
# Vocabulary::QueryComparator doesn't admit `none_in_state` yet (a
# separate, later-landing item in this split registers the new
# comparator word); turned off here so what's under test is this PR's
# own comparator/interpreter pair, not that separate gap.
RSpec.describe "none_in_state, a cross-aggregate anti-join" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["anti-join-growth-", ".bluebook"])
    file.write(source)
    file.flush

    previous = ENV["HECKS_META_VALIDATION"]
    ENV["HECKS_META_VALIDATION"] = "off"

    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      Hecks.hecksagon(hecksagon_name, &binds)
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(
      Hecks::Runtime::Dispatcher.new(registry)
    )
  ensure
    ENV["HECKS_META_VALIDATION"] = previous
    file&.close!
  end

  NONE_IN_STATE_SOURCE = <<~BLUEBOOK
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
      ::AntiJoinGrowth::Claim.persisted_by("Memory")
      ::AntiJoinGrowth::Board.persisted_by("Memory")
    end
  end

  it "excludes an assignment whose claim IS in the named state, and keeps the rest" do
    runtime = boot_anti_join
    runtime.dispatch("AntiJoinGrowth::Claim.File", id: { value: "c1" })  # stays "held"
    runtime.dispatch("AntiJoinGrowth::Claim.File", id: { value: "c2" })
    runtime.dispatch("AntiJoinGrowth::Claim.Release", id: "c2")          # no longer "held"

    runtime.dispatch("AntiJoinGrowth::Board.Open", id: { value: "b1" })
    runtime.dispatch("AntiJoinGrowth::Board.Assign", id: "b1", claim_id: "c1")
    runtime.dispatch("AntiJoinGrowth::Board.Assign", id: "b1", claim_id: "c2")
    # A claim that was never filed at all — "no record in that state" reads
    # the same as "a record, but not in that state".
    runtime.dispatch("AntiJoinGrowth::Board.Assign", id: "b1", claim_id: "nonexistent")

    rows = runtime.query("AntiJoinGrowth::Board.Assignment.Unclaimed")

    expect(rows.map { |row| row[:claim_id] }).to contain_exactly("c2", "nonexistent")
  end
end
