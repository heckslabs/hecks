require "pg"
require "hecks"
require "hecks/adapters/driven/postgres_era"

# The write an unminted boot refuses names both shape labels the boot compared: this checkout's
# and the held era's. Neither label needs a database here: the lineage is a stand-in.
RSpec.describe "the unminted boot's refusal" do
  # Holds the journal's refusal under the state a boot leaves it with.
  class UnmintedLabelsHost
    include Hecks::Adapters::PostgresRevision::Journal

    def initialize(aggregate:, lineage:, era:)
      @aggregate = aggregate
      @lineage = lineage
      @era = era
      @domain = "Ledger"
      @unminted = true
    end

    def table = "acct"
  end

  # Fails every read of the held eras, as a dropped connection does.
  class UnreadableLineage
    def eras = raise(PG::ConnectionBad, "connection lost")
  end

  def ledger_source
    proc do
      aggregate("Acct") do
        identified_by :kind
        attribute :kind, Kind
        value_object("Kind") { attribute :label, String }
      end
    end
  end

  def aggregate
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks.bluebook("Ledger", &ledger_source) }
    registry.bluebooks.values.first.aggregate("Acct")
  end

  def lineage(label) = Struct.new(:eras).new([{ ordinal: 1, label: "000000" }, { ordinal: 2, label: label }])

  def entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "a", state: {}, mirrors: nil)

  def refusal(lineage)
    UnmintedLabelsHost.new(aggregate: aggregate, lineage: lineage, era: 2).refuse_unwritable_boot!(entry)
  rescue Hecks::Runtime::WiringError => e
    e.message
  end

  def current_label = Hecks::Runtime::StorageShape.mint_label(aggregate.hecks_owner)

  it "names this checkout's label and the held era's label" do
    expect(refusal(lineage("abc123"))).to include("(#{current_label}, against held era 2's abc123)")
  end

  it "still names this checkout's label when the held era cannot be read" do
    expect(refusal(UnreadableLineage.new)).to include("(#{current_label}, against held era 2's unknown)")
  end

  it "keeps the instruction to run the mint entry point" do
    expect(refusal(lineage("abc123"))).to include("the shape is not minted yet; run the mint entry point")
  end
end
