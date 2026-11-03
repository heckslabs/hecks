require "spec_helper"
require "hecks/bluebook/model_check"

# A bluebook's `core`, `supporting` or `generic` keys two checks (ADR 0172): a generic context may
# not depend on a core one, and a core context should not be declared conformist to another.
RSpec.describe Hecks::Bluebook::ModelCheck::ClassificationChecks do
  CLASSIFIED = { "Billing" => "core", "Ordering" => "generic", "Shipping" => "supporting" }.freeze unless defined?(CLASSIFIED)

  # Billing, the core context, downstream of Ordering, declared as `as`.
  def map_of(**relate_options)
    Hecks::Bluebook::DSL::ContextMapBuilder.build("Shop") do
      context "Billing"
      context "Ordering"
      relate(**{ "Ordering" => "Billing" }, **relate_options)
    end
  end

  def edge(from, to, kind = "subscription") = { from: from, to: to, kind: kind, via: nil }

  def dependency_kinds(*edges)
    Hecks::Bluebook::ModelCheck.generic_depends_on_core_findings(edges, CLASSIFIED).map(&:kind)
  end

  def conforming_kinds(map) = Hecks::Bluebook::ModelCheck.core_conforms_findings(map, CLASSIFIED).map(&:kind)

  it "reports a generic context that depends on a core one" do
    expect(dependency_kinds(edge("Ordering", "Billing"))).to eq([:generic_depends_on_core])
  end

  it "reports a pair once however many edges join it" do
    expect(dependency_kinds(edge("Ordering", "Billing"), edge("Ordering", "Billing", "acl")).size).to eq(1)
  end

  it "leaves a core context that depends on a generic one alone" do
    expect(dependency_kinds(edge("Billing", "Ordering"))).to be_empty
  end

  it "leaves a context with no classification alone" do
    expect(dependency_kinds(edge("Ordering", "Unclassified"))).to be_empty
  end

  it "warns when a core context is declared conformist" do
    expect(conforming_kinds(map_of(as: :conformist))).to eq([:core_conforms])
  end

  it "leaves a core context behind an anticorruption layer alone" do
    expect(conforming_kinds(map_of(as: :anticorruption_layer))).to be_empty
  end

  it "takes an acknowledgement of a core context that conforms on purpose" do
    acknowledged = map_of(as: :conformist, acknowledges: { core_conforms: "Billing adopts the ledger's model as given" })
    expect(conforming_kinds(acknowledged)).to be_empty
  end
end
