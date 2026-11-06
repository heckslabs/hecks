require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/era_registry_loading"

# A translation decided from the held era's stored shape to the current bluebook: the scaffold's
# diff, the additive rule, the coverage check and the mint decision each read the held side as a
# storage shape, and reach what they reach from the declared bluebook it came from.
RSpec.describe "a translation decided from the held era's stored shape" do
  include EraRegistryLoading

  def manager = Hecks::Adapters::PostgresRevisions::LineageManager

  def source(attributes)
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind

          attribute :kind, Kind
      #{attributes}
          value_object "Kind" do
            attribute :label, String
          end

          value_object "Text" do
            attribute :body, String
          end
        end
      end
    BLUEBOOK
  end

  def held = load_registry(source("    attribute :memo, Text\n")).bluebooks.values.first

  def grown
    load_registry(source("    attribute :memo, Text\n    attribute :note, Text, optional: true\n")).bluebooks.values.first
  end

  def shrunk = load_registry(source("")).bluebooks.values.first

  def held_shape = Hecks::Runtime::StorageShape.project(held)

  def label(bluebook) = Hecks::Runtime::StorageShape.mint_label(bluebook)

  def era = { ordinal: 2, label: label(held), projection: held_shape, hash: nil, held_text: nil }

  Edge = Struct.new(:domain, :from, :to)

  def decide(current, translations: [])
    manager::MintDecision.decide(held: [manager::MintDecision.held_for_decision(era)], bluebook: current,
                                 watermark: 0, rows: [],
                                 edge_source: { translations: translations, recorded: [[label(held), label(current)]] })
  end

  def coverage_refusal(held_side)
    manager.check_coverage!(Hecks::Runtime::Registry.new, shrunk, held_side,
                            Hecks::Translation::ImplicitEdge.new(domain: "Ledger", from: "a", to: "b"))
    nil
  rescue Hecks::Runtime::WiringError => e
    e.message
  end

  it "diffs the stored shape as it diffs the declared bluebook it came from" do
    expect(Hecks::Translation::Scaffold.diff(held_shape, grown)).to eq(Hecks::Translation::Scaffold.diff(held, grown))
  end

  it "takes an optional addition as additive from the stored shape" do
    diff = Hecks::Translation::Scaffold.diff(held_shape, grown)
    expect(Hecks::Translation::ImplicitEdge.qualifies?(diff, held_shape, grown)).to be(true)
  end

  it "refuses a vanished attribute from the stored shape as it does from the declared bluebook", :aggregate_failures do
    refusal = coverage_refusal(manager.held_bluebook(era))
    expect(refusal).to include("memo")
    expect(refusal).to eq(coverage_refusal(held))
  end

  it "mints an additive move from a held era whose only record of its shape is the stored one" do
    expect(decide(grown)).to have_attributes(verdict: "would_mint", source: "implicit")
  end

  it "takes the edge that leads to the current shape beside an edge to another shape" do
    edges = [Edge.new("Ledger", label(held), "elsewhere"), Edge.new("Ledger", label(held), label(grown))]
    expect(decide(grown, translations: edges)).to have_attributes(verdict: "would_mint", source: "file")
  end

  it "decides by the diff when the only edges from the held era lead to another shape" do
    expect(decide(grown, translations: [Edge.new("Ledger", label(held), "elsewhere")]))
      .to have_attributes(verdict: "would_mint", source: "implicit")
  end

  it "refuses two edges that both lead the held era to the current shape, by name" do
    edges = [Edge.new("Ledger", label(held), label(grown))] * 2
    expect(decide(grown, translations: edges)).to have_attributes(verdict: "refused", reason: :duplicate_edge)
  end
end
