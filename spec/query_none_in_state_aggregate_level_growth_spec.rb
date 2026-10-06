require "spec_helper"
require "tempfile"

# Pins none_in_state on an aggregate-level query against a Memory-backed aggregate.
# Ports::Query::InMemory#holds? once lacked the case and excluded every row.
RSpec.describe "none_in_state on an ordinary AGGREGATE-level Memory query" do
  def write_bluebook(source)
    Tempfile.new(["anti-join-aggregate-growth-", ".bluebook"]).tap do |file|
      file.write(source)
      file.flush
    end
  end

  def declare_in(registry, file, source, hecksagon_name, &binds)
    Hecks::Bluebook::MetaValidator.while_disabled do
      Hecks.with_registry(registry) do
        [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
         InMemoryDomain::PRISM_ADAPTER].each { |port| Kernel.load(port) }
        Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
        Hecks.hecksagon(hecksagon_name, &binds)
      end
    end
  end

  def boot(source, hecksagon_name, &binds)
    file = write_bluebook(source)
    registry = Hecks::Runtime::Registry.new
    declare_in(registry, file, source, hecksagon_name, &binds)

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  ensure
    file&.close!
  end

  AGGREGATE_ANTI_JOIN_SOURCE = <<~BLUEBOOK.freeze
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
          sets :state, to: { value: "released" }
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
      AggregateAntiJoinGrowth::Claim.persisted_by("Memory")
      AggregateAntiJoinGrowth::Board.persisted_by("Memory")
    end
  end

  def file_claims(runtime)
    runtime.dispatch_flat("AggregateAntiJoinGrowth::Claim.File", id: { value: "c1" })
    runtime.dispatch_flat("AggregateAntiJoinGrowth::Claim.File", id: { value: "c2" })
    runtime.dispatch_flat("AggregateAntiJoinGrowth::Claim.Release", id: "c2")
  end

  def open_boards(runtime)
    runtime.dispatch_flat("AggregateAntiJoinGrowth::Board.Open", id: { value: "b1" }, claim_id: "c1")
    runtime.dispatch_flat("AggregateAntiJoinGrowth::Board.Open", id: { value: "b2" }, claim_id: "c2")
    runtime.dispatch_flat("AggregateAntiJoinGrowth::Board.Open", id: { value: "b3" }, claim_id: "nonexistent")
  end

  it "excludes an aggregate-level row whose claim IS in the named state, and keeps the rest" do
    runtime = boot_aggregate_anti_join
    file_claims(runtime)
    open_boards(runtime)

    rows = runtime.query("AggregateAntiJoinGrowth::Board.Unclaimed")

    expect(rows.map { |row| row[:id] }).to contain_exactly("b2", "b3")
  end
end
