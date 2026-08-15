require "spec_helper"
require "tempfile"

# Real dispatch coverage for the aggregate-level none_in_state gap:
# Runtime::QueryInterpreter#holds? (the entity/sub-list query path, and
# the fallback when no adapter implements :query) already had
# none_in_state -- Ports::Query::InMemory#holds? ("the path that
# actually runs for a memory- or heki-backed aggregate query" per its
# own existing comment) never had a matching case, so an ORDINARY
# aggregate-level none_in_state where-clause against a Memory-backed
# aggregate silently fell to the else branch (held == want, an id
# string against "Aggregate:state", never equal) and excluded every
# row, every time. Distinct from spec/query_none_in_state_growth_spec.rb,
# which exercises the entity-level path this gap does not touch.
RSpec.describe "none_in_state on an ordinary AGGREGATE-level Memory query" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["anti-join-aggregate-growth-", ".bluebook"])
    file.write(source)
    file.flush

    previous = ENV["HECKSAGAIN_META_VALIDATION"]
    ENV["HECKSAGAIN_META_VALIDATION"] = "off"

    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      Hecks.hecksagon(hecksagon_name, &binds)
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(
      Hecksagain::Runtime::Dispatcher.new(registry)
    )
  ensure
    ENV["HECKSAGAIN_META_VALIDATION"] = previous
    file&.close!
  end

  AGGREGATE_ANTI_JOIN_SOURCE = <<~BLUEBOOK
    Hecks.bluebook "AggregateAntiJoinGrowth" do
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
          then_set :state, to: { value: "released" }
        end
      end

      aggregate "Board" do
        identified_by :id

        value_object "BoardId" do
          attribute :value, String
        end

        attribute :id,       BoardId
        attribute :claim_id, String

        command "Open" do
          attribute :id,       BoardId
          attribute :claim_id, String
          emits "Opened"
        end

        query "Unclaimed" do
          where claim_id: { none_in_state: "Claim:held" }
        end
      end
    end
  BLUEBOOK

  def boot_aggregate_anti_join
    boot(AGGREGATE_ANTI_JOIN_SOURCE, "AggregateAntiJoinGrowth") do
      ::AggregateAntiJoinGrowth::Claim.persisted_by("Memory")
      ::AggregateAntiJoinGrowth::Board.persisted_by("Memory")
    end
  end

  it "excludes an aggregate-level row whose claim IS in the named state, and keeps the rest" do
    runtime = boot_aggregate_anti_join
    runtime.dispatch("AggregateAntiJoinGrowth::Claim.File", id: { value: "c1" }) # stays "held"
    runtime.dispatch("AggregateAntiJoinGrowth::Claim.File", id: { value: "c2" })
    runtime.dispatch("AggregateAntiJoinGrowth::Claim.Release", id: "c2")         # no longer "held"

    runtime.dispatch("AggregateAntiJoinGrowth::Board.Open", id: { value: "b1" }, claim_id: "c1")
    runtime.dispatch("AggregateAntiJoinGrowth::Board.Open", id: { value: "b2" }, claim_id: "c2")
    # A claim that was never filed at all — "no record in that state" reads
    # the same as "a record, but not in that state".
    runtime.dispatch("AggregateAntiJoinGrowth::Board.Open", id: { value: "b3" }, claim_id: "nonexistent")

    rows = runtime.query("AggregateAntiJoinGrowth::Board.Unclaimed")

    expect(rows.map { |row| row[:id] }).to contain_exactly("b2", "b3")
  end
end
