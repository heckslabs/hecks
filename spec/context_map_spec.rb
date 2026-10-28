require "spec_helper"
require "hecks/bluebook/model_check"
require "hecks/projections/context_map_diagram"

# A declared context map, held against the wiring's derived edges (ADR 0135). Edges are plain
# hashes, as `Projections::ContextRelationships.call` answers them: from the context that depends
# to the one it depends on.
RSpec.describe Hecks::Bluebook::ContextMap do
  def relationship(upstream, downstream, kind, published: [], shared: [])
    described_class::Relationship.new(upstream: upstream, downstream: downstream, kind: kind,
                                      published: published, shared: shared)
  end

  def map(*relationships, separate_ways: [])
    contexts = %w[Billing Ordering Shipping Governance].map do |name|
      described_class::Context.new(name: name, team: "#{name.downcase}-team")
    end
    described_class.new(name: "Shop", contexts: contexts, relationships: relationships,
                        separate_ways: separate_ways)
  end

  def edge(from, to, kind, via = nil) = { from: from, to: to, kind: kind, via: via }

  def findings(declared, *edges) = Hecks::Bluebook::ModelCheck.context_map_findings(declared, edges)

  def kinds(declared, *edges) = findings(declared, *edges).map(&:kind)

  describe "the map" do
    it "refuses a relationship of an unknown kind" do
      expect { map(relationship("Billing", "Ordering", :friendship)) }
        .to raise_error(ArgumentError, /unknown relationship kind :friendship/)
    end

    it "refuses a relationship naming a context the map does not declare" do
      expect { map(relationship("Billing", "Warehouse", :conformist)) }
        .to raise_error(ArgumentError, /Warehouse, which it does not declare/)
    end

    it "finds the relationships between two contexts whichever way the arrow runs" do
      declared = map(relationship("Billing", "Ordering", :customer_supplier))
      expect(declared.relationships_between("Ordering", "Billing").size).to eq(1)
    end
  end

  describe "holding the wiring to the map" do
    let(:billing_supplies_ordering) do
      map(relationship("Billing", "Ordering", :customer_supplier, published: %w[Billing.InvoicePaid]))
    end

    it "checks nothing without a map" do
      expect(findings(nil, edge("Ordering", "Billing", "customer_supplier", "Pay"))).to be_empty
    end

    it "accepts a coupling the map declares as the kind the wiring implements" do
      expect(kinds(billing_supplies_ordering, edge("Ordering", "Billing", "customer_supplier", "Pay")))
        .to be_empty
    end

    it "reports a coupling between contexts the map does not relate", :aggregate_failures do
      found = findings(billing_supplies_ordering, edge("Ordering", "Shipping", "subscription", "Shipping.Sent"))
      expect(found.map(&:kind)).to eq(%i[undeclared_coupling unused_relationship])
      expect(found.first.severity).to eq(:error)
      expect(found.first.subject).to eq("Ordering -> Shipping")
    end

    it "reports a coupling that runs against the declared direction" do
      found = findings(billing_supplies_ordering, edge("Billing", "Ordering", "customer_supplier", "Bill"))
      expect(found.first.message).to include("the other way round")
    end

    it "reports a wiring kind the declared kind does not allow" do
      declared = map(relationship("Shipping", "Ordering", :customer_supplier))
      expect(kinds(declared, edge("Ordering", "Shipping", "acl", "Quote"))).to eq([:relationship_kind_mismatch])
    end

    it "takes a subscription as a conformist unless the map says another kind" do
      declared = map(relationship("Governance", "Ordering", :conformist))
      expect(kinds(declared, edge("Ordering", "Governance", "subscription", "Governance.Granted"))).to be_empty
    end

    it "takes an attach as a conformist, or as a shared kernel the map declares" do
      declared = map(relationship("Governance", "Ordering", :shared_kernel, shared: %w[Principal]))
      expect(kinds(declared, edge("Ordering", "Governance", "shared_kernel"))).to be_empty
    end

    it "warns when a conformist translates" do
      declared = map(relationship("Governance", "Ordering", :conformist))
      found = findings(declared, edge("Ordering", "Governance", "acl", "Translate"))
      expect(found.map { |finding| [finding.kind, finding.severity] }).to eq([[:conformist_translates, :warning]])
    end

    it "reports a subscription to an event the supplier does not publish" do
      found = findings(billing_supplies_ordering, edge("Ordering", "Billing", "subscription", "Billing.Refunded"))
      expect(found.map(&:kind)).to eq([:unpublished_dependency])
    end

    it "accepts a subscription to a published event" do
      expect(kinds(billing_supplies_ordering, edge("Ordering", "Billing", "subscription", "Billing.InvoicePaid")))
        .to be_empty
    end

    it "reports any coupling between contexts declared separate ways" do
      declared = map(separate_ways: [%w[Shipping Billing]])
      expect(kinds(declared, edge("Billing", "Shipping", "subscription", "Shipping.Sent")))
        .to eq([:separate_ways_violated])
    end

    it "warns of a declared relationship the wiring never uses", :aggregate_failures do
      found = findings(billing_supplies_ordering)
      expect(found.map(&:kind)).to eq([:unused_relationship])
      expect(found.first.severity).to eq(:warning)
    end
  end

  describe "drawing the map" do
    let(:diagram) do
      declared = map(relationship("Billing", "Ordering", :customer_supplier),
                     relationship("Governance", "Ordering", :conformist),
                     relationship("Shipping", "Billing", :partnership),
                     separate_ways: [%w[Shipping Governance]])
      edges = [edge("Ordering", "Billing", "customer_supplier", "Pay"),
               edge("Ordering", "Shipping", "subscription", "Shipping.Sent")]
      Hecks::Projections::ContextMapDiagram.call(map: declared, edges: edges)
    end

    it "labels each context with its team" do
      expect(diagram).to include('Ordering["Ordering<br/>ordering-team"]')
    end

    it "draws a relationship with the standard end marks, upstream to downstream", :aggregate_failures do
      expect(diagram).to include('Billing -- "U/S → D/C" --> Ordering')
      expect(diagram).to include('Governance -- "U → D/CF" --> Ordering')
      expect(diagram).to include('Shipping <-- "P" --> Billing')
    end

    it "draws a coupling the map does not declare dashed and red", :aggregate_failures do
      expect(diagram).to include('Shipping -. "subscription" .-> Ordering')
      expect(diagram).to include("linkStyle 3 stroke:#c00")
    end

    it "draws a declared relationship the wiring never uses grey" do
      expect(diagram).to include("linkStyle 1 stroke:#999")
    end

    it "lists the contexts declared separate ways beside the diagram" do
      expect(diagram).to include("%% separate ways: Governance | Shipping")
    end
  end
end
