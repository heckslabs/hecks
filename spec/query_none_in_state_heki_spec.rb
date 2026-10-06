require "spec_helper"
require "tempfile"
require "tmpdir"

# Pins none_in_state against a Heki-backed aggregate: Heki#query must pass `context:`
# through, or the comparator answers true for every row. Same fixture as the Memory spec.
RSpec.describe "none_in_state on an ordinary AGGREGATE-level Heki query" do
  around do |example|
    @dir = Dir.mktmpdir("hecks-heki-none-in-state-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  HEKI_SPEC_FILES = [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
                     File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/heki.adapter"),
                     InMemoryDomain::PRISM_ADAPTER].freeze

  # Loads the ports and adapters, evaluates the bluebook `source` read from `path`, and declares the
  # hecksagon `hecksagon_name` with `binds`, all into `registry`.
  def load_heki_domain(registry, source, path, hecksagon_name, &binds)
    Hecks::Bluebook::MetaValidator.while_disabled do
      Hecks.with_registry(registry) do
        HEKI_SPEC_FILES.each { |file| Kernel.load(file) }
        Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
        Hecks.hecksagon(hecksagon_name, &binds)
      end
    end
  end

  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["anti-join-aggregate-heki-", ".bluebook"])
    file.write(source)
    file.flush

    registry = Hecks::Runtime::Registry.new(root: @dir)
    load_heki_domain(registry, source, file.path, hecksagon_name, &binds)

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  ensure
    file&.close!
  end

  AGGREGATE_ANTI_JOIN_HEKI_SOURCE = <<~BLUEBOOK.freeze
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
    boot(AGGREGATE_ANTI_JOIN_HEKI_SOURCE, "AggregateAntiJoinHekiGrowth") do
      AggregateAntiJoinHekiGrowth::Claim.persisted_by("Heki")
      AggregateAntiJoinHekiGrowth::Board.persisted_by("Heki")
    end
  end

  # Claims c1 and c2 (c2 released), and boards b1, b2 and b3 pointing at c1, c2 and a claim that is not there.
  def seed_claims_and_boards(runtime)
    runtime.dispatch_flat("AggregateAntiJoinHekiGrowth::Claim.File", id: { value: "c1" })
    runtime.dispatch_flat("AggregateAntiJoinHekiGrowth::Claim.File", id: { value: "c2" })
    runtime.dispatch_flat("AggregateAntiJoinHekiGrowth::Claim.Release", id: "c2")
    runtime.dispatch_flat("AggregateAntiJoinHekiGrowth::Board.Open", id: { value: "b1" }, claim_id: "c1")
    runtime.dispatch_flat("AggregateAntiJoinHekiGrowth::Board.Open", id: { value: "b2" }, claim_id: "c2")
    runtime.dispatch_flat("AggregateAntiJoinHekiGrowth::Board.Open", id: { value: "b3" }, claim_id: "nonexistent")
  end

  it "excludes an aggregate-level row whose claim IS in the named state, and keeps the rest" do
    runtime = boot_aggregate_anti_join
    seed_claims_and_boards(runtime)

    rows = runtime.query("AggregateAntiJoinHekiGrowth::Board.Unclaimed")

    expect(rows.map { |row| row[:id] }).to contain_exactly("b2", "b3")
  end
end
