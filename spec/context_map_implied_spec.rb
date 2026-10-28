require "spec_helper"
require "hecks/bluebook/model_check"
require "hecks/projections/context_map_diagram"

# An `attaches` is a conformist relationship the map need not write down (ADR 0155): the map says
# only what an attach cannot, and an explicit relationship between the same pair overrides it.
RSpec.describe "implied conformist relationships" do
  let(:map_class) { Hecks::Bluebook::ContextMap }
  let(:attach) { { from: "Shop", to: "Governance", kind: "shared_kernel", via: nil } }

  def relationship(upstream, downstream, kind, **rest)
    map_class::Relationship.new(upstream: upstream, downstream: downstream, kind: kind, **rest)
  end

  def map(*relationships, separate_ways: [])
    contexts = %w[Shop Governance Billing].map { |name| map_class::Context.new(name: name) }
    map_class.new(name: "Shop", contexts: contexts, relationships: relationships, separate_ways: separate_ways)
  end

  def kinds(declared, *edges) = Hecks::Bluebook::ModelCheck.context_map_findings(declared, edges).map(&:kind)

  it "accepts an attach the map does not mention" do
    expect(kinds(map, attach)).to be_empty
  end

  it "reads the attach as a conformist, upstream the attached context", :aggregate_failures do
    implied = map.implying([attach]).relationships.first
    expect([implied.upstream, implied.downstream, implied.kind, implied.implied])
      .to eq(["Governance", "Shop", :conformist, true])
  end

  it "does not imply a relationship for a pair the map already relates" do
    declared = map(relationship("Governance", "Shop", :shared_kernel))
    expect(declared.implying([attach]).relationships.size).to eq(1)
  end

  it "lets a declared kind override the implied one" do
    expect(kinds(map(relationship("Governance", "Shop", :open_host)), attach)).to be_empty
  end

  it "still reports an attach between contexts declared separate ways" do
    expect(kinds(map(separate_ways: [%w[Shop Governance]]), attach)).to eq([:separate_ways_violated])
  end

  it "never reports an implied relationship as unused" do
    expect(kinds(map)).to be_empty
  end

  it "warns of a conformist line that only the attach explains" do
    expect(kinds(map(relationship("Governance", "Shop", :conformist)), attach)).to eq([:redundant_relationship])
  end

  it "does not call a conformist redundant when something besides the attach couples the pair" do
    translate = { from: "Shop", to: "Governance", kind: "acl", via: "Translate" }
    expect(kinds(map(relationship("Governance", "Shop", :conformist)), attach, translate))
      .not_to include(:redundant_relationship)
  end

  it "lets the relationship acknowledge the redundancy" do
    kept = { redundant_relationship: "kept for the diagram" }
    expect(kinds(map(relationship("Governance", "Shop", :conformist, acknowledged: kept)), attach)).to be_empty
  end

  it "draws an implied attach dotted and labelled attaches" do
    expect(Hecks::Projections::ContextMapDiagram.call(map: map, edges: [attach]))
      .to include('Governance -. "attaches · U → D/CF" .-> Shop')
  end
end
