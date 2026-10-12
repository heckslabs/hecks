require "spec_helper"
require_relative "../../../lib/hecks/hecks/adapters/rehearsal"

# What a rehearsal says it audited, and how the two engines stood against each other.
RSpec.describe Hecks::Adapters::Rehearsal::AuditReport do
  let(:edge) { Struct.new(:from, :to).new("aaaaaa", "bbbbbb") }
  let(:result_class) { Hecks::Adapters::Rehearsal::RustAudit::Result }
  let(:states) { { "Widget" => { "w1" => {}, "w2" => {} }, "Order" => {} } }

  def rust(ran: true, violations: [])
    result_class.new(ran: ran, violations: violations, note: ran ? "ran over 2 rows" : "no harness", rows: ran ? 2 : 0)
  end

  def report(minting: "next", edge: self.edge, ruby: [], rust: self.rust)
    described_class.new(minting: minting, edge: edge, states: states, ruby: ruby, rust: rust)
  end

  it "counts the rows and the aggregates it read through an edge", :aggregate_failures do
    facts = report.facts

    expect(facts[:audited]).to eq(value: true)
    expect(facts.values_at(:rows_examined, :aggregates_examined)).to eq([{ value: 2 }, { value: 1 }])
  end

  it "says no stored row was examined when the shape stands", :aggregate_failures do
    held = report(minting: "none", edge: nil)

    expect(held.facts[:audited]).to eq(value: false)
    expect(held.limits.first).to include(what: "the stored rows", why: /no mint is needed at this shape/)
  end

  it "carries no limit when it audited" do
    expect(report.limits).to eq([])
  end

  it "agrees when both engines refuse the same records" do
    both = report(ruby: ["Widget#w1: a"], rust: rust(violations: ["Widget#w1: b"]))

    expect(both.parity).to include(status: "agree")
  end

  it "says which engine refused what when they differ", :aggregate_failures do
    differing = report(rust: rust(violations: ["Widget#w2: Band admits small"])).parity

    expect(differing[:status]).to eq("differ")
    expect(differing[:note]).to include("Only rust refused: Widget#w2", "Ruby audit's first layer does not yet")
  end

  it "does not call a Ruby-only refusal the known gap", :aggregate_failures do
    note = report(ruby: ["Widget#w1: x"]).parity[:note]

    expect(note).to include("Only ruby refused: Widget#w1")
    expect(note).not_to include("known difference")
  end

  it "is not run when no harness was built" do
    expect(report(rust: rust(ran: false)).parity).to include(status: "not_run")
  end
end
