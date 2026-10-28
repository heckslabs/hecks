require "spec_helper"
require "hecks/fuzzing/isolated_boot"
require "hecks/bluebook/model_check"
require "hecks/projections/context_map_diagram"

# Banking's context map, declared and held against its real wiring (ADR 0135). Compliance and
# Notifications are suppliers Banking reacts to across a boundary; Governance, Identity and Bulk
# are bluebooks it attaches and takes as they are.
RSpec.describe "Banking's context map" do
  def relationship(upstream, downstream, kind, published: [])
    Hecks::Bluebook::ContextMap::Relationship.new(upstream: upstream, downstream: downstream, kind: kind,
                                                  published: published, shared: [])
  end

  let(:declared) do
    [
      relationship("Compliance", "Banking", :customer_supplier, published: %w[AccountFreezeReviewOpened]),
      relationship("Notifications", "Banking", :customer_supplier),
      relationship("Governance", "Banking", :conformist),
      relationship("Identity", "Banking", :conformist),
      relationship("Bulk", "Banking", :conformist),
      relationship("Governance", "Identity", :conformist),
      relationship("Governance", "Bulk", :conformist)
    ]
  end

  let(:contexts) do
    %w[Banking Compliance Notifications Governance Identity Bulk].map do |name|
      Hecks::Bluebook::ContextMap::Context.new(name: name, team: nil)
    end
  end

  let(:edges) do
    Hecks::Fuzzing::IsolatedBoot.call("examples/banking") do |copy|
      return Hecks::Projections::ContextRelationships.call(registry: Hecks.boot(copy).registry)
    end
  end

  def banking_map(*without)
    kept = declared.reject { |rel| without.include?(rel.upstream) && rel.downstream == "Banking" }
    Hecks::Bluebook::ContextMap.new(name: "Banking", contexts: contexts, relationships: kept)
  end

  def findings(map) = Hecks::Bluebook::ModelCheck.context_map_findings(map, edges)

  it "holds Banking's wiring to its declared relationships" do
    expect(findings(banking_map).map(&:to_s)).to be_empty
  end

  it "reports the Compliance coupling once the map stops declaring it", :aggregate_failures do
    found = findings(banking_map("Compliance"))
    expect(found.map(&:kind).uniq).to eq([:undeclared_coupling])
    expect(found.map(&:subject).uniq).to eq(["Banking -> Compliance"])
  end

  it "draws the declared map beside the wiring" do
    diagram = Hecks::Projections::ContextMapDiagram.call(map: banking_map, edges: edges)
    expect(diagram).to include('Compliance -- "U/S → D/C" --> Banking')
  end
end
