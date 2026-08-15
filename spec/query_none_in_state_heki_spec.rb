require "spec_helper"
require "tempfile"
require "tmpdir"

# §9 — `Heki#query` never threaded `context:` through to
# `Ports::Query::InMemory.execute` (always passed `registry: nil`),
# which makes `none_in_state?` unconditionally answer `true` — its own
# graceful "no registry, no way to look the target up" default — for
# EVERY `none_in_state` where-clause against ANY Heki-backed aggregate,
# always, no matter the actual target state. Silently excluded
# nothing. Same fixture and query shape
# spec/query_none_in_state_aggregate_level_growth_spec.rb already
# proves against Memory (which already threaded `context:` correctly);
# this proves the identical case against Heki, the adapter that
# didn't.
RSpec.describe "none_in_state on an ordinary AGGREGATE-level Heki query" do
  around do |example|
    @dir = Dir.mktmpdir("hecksagain-heki-none-in-state-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["anti-join-aggregate-heki-", ".bluebook"])
    file.write(source)
    file.flush

    previous = ENV["HECKSAGAIN_META_VALIDATION"]
    ENV["HECKSAGAIN_META_VALIDATION"] = "off"

    registry = Hecksagain::Runtime::Registry.new(root: @dir)
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecksagain/adapters/driven/heki.adapter"))
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

  AGGREGATE_ANTI_JOIN_HEKI_SOURCE = <<~BLUEBOOK
    Hecks.bluebook "AggregateAntiJoinHekiGrowth" do
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
    boot(AGGREGATE_ANTI_JOIN_HEKI_SOURCE, "AggregateAntiJoinHekiGrowth") do
      ::AggregateAntiJoinHekiGrowth::Claim.persisted_by("Heki")
      ::AggregateAntiJoinHekiGrowth::Board.persisted_by("Heki")
    end
  end

  it "excludes an aggregate-level row whose claim IS in the named state, and keeps the rest" do
    runtime = boot_aggregate_anti_join
    runtime.dispatch("AggregateAntiJoinHekiGrowth::Claim.File", id: { value: "c1" }) # stays "held"
    runtime.dispatch("AggregateAntiJoinHekiGrowth::Claim.File", id: { value: "c2" })
    runtime.dispatch("AggregateAntiJoinHekiGrowth::Claim.Release", id: "c2")         # no longer "held"

    runtime.dispatch("AggregateAntiJoinHekiGrowth::Board.Open", id: { value: "b1" }, claim_id: "c1")
    runtime.dispatch("AggregateAntiJoinHekiGrowth::Board.Open", id: { value: "b2" }, claim_id: "c2")
    # A claim that was never filed at all — "no record in that state" reads
    # the same as "a record, but not in that state".
    runtime.dispatch("AggregateAntiJoinHekiGrowth::Board.Open", id: { value: "b3" }, claim_id: "nonexistent")

    rows = runtime.query("AggregateAntiJoinHekiGrowth::Board.Unclaimed")

    expect(rows.map { |row| row[:id] }).to contain_exactly("b2", "b3")
  end
end
