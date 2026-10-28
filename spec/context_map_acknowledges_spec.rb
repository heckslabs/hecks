require "spec_helper"
require "hecks/bluebook/model_check"

# A relationship in a `.contextmap` can acknowledge the findings about itself, each with a reason
# (ADR 0150). A finding with no relationship to carry the allowance cannot be acknowledged.
RSpec.describe Hecks::Bluebook::DSL::ContextMapBuilder do
  def map_of(relate_options)
    described_class.build("Shop") do
      context "Billing"
      context "Ordering"
      relate(**{ "Billing" => "Ordering" }, **relate_options)
    end
  end

  def edge(kind, via = nil) = { from: "Ordering", to: "Billing", kind: kind, via: via }

  def kinds(declared, *edges) = Hecks::Bluebook::ModelCheck.context_map_findings(declared, edges).map(&:kind)

  def acknowledging(kind, as: :conformist, **rest)
    map_of(as: as, acknowledges: { kind => "the supplier's model is ours too" }, **rest)
  end

  it "holds the acknowledgement on the relationship" do
    expect(acknowledging(:conformist_translates).relationships.first.acknowledges?(:conformist_translates))
      .to be(true)
  end

  it "stops a conformist that translates from being reported" do
    expect(kinds(acknowledging(:conformist_translates), edge("acl", "Quote"))).to be_empty
  end

  it "reports the same conformist that translates without the acknowledgement" do
    expect(kinds(map_of(as: :conformist), edge("acl", "Quote"))).to eq([:conformist_translates])
  end

  it "stops a kind mismatch from being reported" do
    declared = acknowledging(:relationship_kind_mismatch, as: :customer_supplier)
    expect(kinds(declared, edge("acl", "Quote"))).to be_empty
  end

  it "stops an unpublished dependency from being reported" do
    declared = acknowledging(:unpublished_dependency, as: :customer_supplier, published: %w[Billing.Paid])
    expect(kinds(declared, edge("subscription", "Billing.Refunded"))).to be_empty
  end

  it "stops an unused relationship from being reported" do
    expect(kinds(acknowledging(:unused_relationship), edge("subscription", "Other"))).to eq([])
  end

  it "refuses a finding no relationship can carry" do
    expect { acknowledging(:undeclared_coupling) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Billing => Ordering acknowledges :undeclared_coupling/)
  end

  it "refuses an acknowledgement without a reason" do
    expect { map_of(as: :conformist, acknowledges: { conformist_translates: "" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /without a reason/)
  end
end
