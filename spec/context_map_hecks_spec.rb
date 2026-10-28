require "spec_helper"
require "hecks/bluebook/model_check"
require "hecks/projections/context_map_diagram"

# The Hecks domain's context map is `hecks.contextmap` beside its bluebooks (ADR 0135): Hecks and
# the bluebooks it attaches, each of which attaches Governance, and the one place Deploy's model is
# translated into Tenancy's.
RSpec.describe "The Hecks domain's context map" do
  let(:registry) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false).registry }
  let(:declared) { registry.context_map("Hecks") }
  let(:edges) { Hecks::Projections::ContextRelationships.call(registry: registry) }

  def findings(map) = Hecks::Bluebook::ModelCheck.context_map_findings(map, edges)

  # The declared map without the relationship from `upstream` to `downstream`.
  def without(upstream, downstream)
    kept = declared.relationships.reject { |rel| rel.upstream == upstream && rel.downstream == downstream }
    Hecks::Bluebook::ContextMap.new(name: "Hecks", contexts: declared.contexts, relationships: kept)
  end

  it "holds the wiring to the declared relationships" do
    expect(findings(declared).map(&:to_s)).to be_empty
  end

  it "reads the Tenancy translation as coming from Deploy, whose Tenant emits the event" do
    expect(edges).to include(from: "Tenancy", to: "Deploy", kind: "acl", via: "RegisterProvisionedTenant")
  end

  it "reports the translation once the map stops declaring it", :aggregate_failures do
    found = findings(without("Deploy", "Tenancy"))
    expect(found.map(&:kind).uniq).to eq([:undeclared_coupling])
    expect(found.map(&:subject).uniq).to eq(["Tenancy -> Deploy"])
  end
end
