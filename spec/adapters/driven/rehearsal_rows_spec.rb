require "spec_helper"
require_relative "../../../lib/hecks/hecks/adapters/rehearsal"

# How the mint audit's refusals become the rows of a rehearsal's report.
RSpec.describe Hecks::Adapters::Rehearsal::Rows do
  it "reads the audit's wording as an aggregate, an id, a rule and the words", :aggregate_failures do
    row = described_class.row("Widget#w3: status is \"gone\", a state this era's lifecycle never reaches")

    expect(row).to include(aggregate: "Widget", id: "w3", rule: "lifecycle")
    expect(row[:wording]).to start_with("status is")
  end

  it "holds a refusal that names no record under the edge" do
    expect(described_class.row("Widget: the id set changed across the edge (lost [], gained [\"a\"])"))
      .to include(aggregate: "(edge)", rule: "reference")
  end

  it "caps the rows and counts them all", :aggregate_failures do
    rows, total = described_class.from(Array.new(60) { |n| "Widget#w#{n}: a band is bad" })

    expect(rows.size).to eq(described_class::CAP)
    expect(total).to eq(60)
  end
end
