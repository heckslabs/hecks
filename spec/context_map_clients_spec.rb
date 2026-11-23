require "spec_helper"
require "hecks/bluebook/model_check"
require "hecks/projections/context_map_diagram"

# The Clients context stands apart from every public context of the Hecks map: client material
# never enters the public repo, so any coupling between them is refused by `model_check`.
RSpec.describe "The Hecks context map's Clients boundary" do
  let(:registry) { boot_hecks_in_memory.registry }
  let(:declared) { registry.context_map("Hecks") }
  let(:public_contexts) { declared.context_names - ["Clients"] }

  def edge(from, to, kind) = { from: from, to: to, kind: kind, via: nil }

  def findings(*edges) = Hecks::Bluebook::ModelCheck.context_map_findings(declared, edges)

  it "declares the Clients context" do
    expect(declared.context_names).to include("Clients")
  end

  it "declares every public context separate ways from Clients" do
    expect(public_contexts.reject { |name| declared.separate?(name, "Clients") }).to be_empty
  end

  it "loads clean: the wiring and the map agree" do
    edges = Hecks::Projections::ContextRelationships.call(registry: registry)
    expect(findings(*edges).map(&:to_s)).to be_empty
  end

  %w[shared_kernel acl subscription customer_supplier].each do |kind|
    it "refuses a #{kind} coupling between a public context and Clients, either way round", :aggregate_failures do
      [edge("Tickets", "Clients", kind), edge("Clients", "Tickets", kind)].each do |coupling|
        expect(findings(coupling).map(&:kind)).to eq([:separate_ways_violated])
      end
    end
  end

  it "refuses the Hecks context itself attaching Clients" do
    expect(findings(edge("Hecks", "Clients", "shared_kernel")).map(&:severity)).to eq([:error])
  end
end
