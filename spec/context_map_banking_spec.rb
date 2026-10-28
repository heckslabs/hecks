require "spec_helper"
require "hecks/fuzzing/isolated_boot"
require "hecks/bluebook/model_check"
require "hecks/projections/context_map_diagram"

# Banking's context map is the `banking.contextmap` file beside its bluebooks (ADR 0135), loaded at
# boot and held against the wiring it covers. Compliance and Notifications are suppliers Banking
# reacts to across a boundary; Governance, Identity and Bulk are bluebooks it attaches.
RSpec.describe "Banking's context map" do
  let(:registry) do
    Hecks::Fuzzing::IsolatedBoot.call("examples/banking") { |copy| return Hecks.boot(copy).registry }
  end

  let(:declared) { registry.context_map("Banking") }
  let(:edges) { Hecks::Projections::ContextRelationships.call(registry: registry) }

  def findings(map) = Hecks::Bluebook::ModelCheck.context_map_findings(map, edges)

  # The declared map without the relationships that supply `upstream` to Banking.
  def without(upstream)
    kept = declared.relationships.reject { |rel| rel.upstream == upstream && rel.downstream == "Banking" }
    Hecks::Bluebook::ContextMap.new(name: "Banking", contexts: declared.contexts, relationships: kept)
  end

  it "is read from the file Banking boots, with its suppliers and consumers" do
    expect(declared.relationships.map { |rel| [rel.upstream, rel.downstream, rel.kind] })
      .to include(["Compliance", "Banking", :customer_supplier], ["Governance", "Banking", :conformist])
  end

  it "holds Banking's wiring to its declared relationships" do
    expect(findings(declared).map(&:to_s)).to be_empty
  end

  it "reports the Compliance coupling once the map stops declaring it", :aggregate_failures do
    found = findings(without("Compliance"))
    expect(found.map(&:kind).uniq).to eq([:undeclared_coupling])
    expect(found.map(&:subject).uniq).to eq(["Banking -> Compliance"])
  end

  it "draws the declared map beside the wiring" do
    diagram = Hecks::Projections::ContextMapDiagram.call(map: declared, edges: edges)
    expect(diagram).to include('Compliance -- "U/S → D/C" --> Banking')
  end
end
