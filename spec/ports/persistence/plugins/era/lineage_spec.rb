require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# Renames apply as one simultaneous permutation, so a swap or chain never reads a key
# a prior rule already wrote. Layer 2 audits SQL against this reference transform.
RSpec.describe "Lineage#translate — simultaneous rename application" do
  def entry_with(state)
    Hecks::Ports::Persistence::Entry.new(operation: "save", id: "r1", state: state)
  end

  it "a two-way swap preserves BOTH values, never collapsing one into the other" do
    lineage = Hecks::Ports::Persistence::Lineage.new({ a: :b, b: :a })

    result = lineage.translate(entry_with(a: 1, b: 2))

    expect(result.state).to eq(a: 2, b: 1)
  end

  it "the swap is order-independent — declaring the pair the other way round answers the same" do
    lineage = Hecks::Ports::Persistence::Lineage.new({ b: :a, a: :b })

    result = lineage.translate(entry_with(a: 1, b: 2))

    expect(result.state).to eq(a: 2, b: 1)
  end

  it "a three-way rotation (a->b->c->a) permutes every value, none lost" do
    lineage = Hecks::Ports::Persistence::Lineage.new({ a: :b, b: :c, c: :a })

    result = lineage.translate(entry_with(a: 1, b: 2, c: 3))

    expect(result.state).to eq(a: 3, b: 1, c: 2)
  end

  it "a chain into a fresh name (a->b, b->c) moves a's value to c and drops the ORIGINAL b, simultaneously" do
    # Each rule reads the original snapshot, so c gets the original b (2), not a's value.
    lineage = Hecks::Ports::Persistence::Lineage.new({ a: :b, b: :c })

    result = lineage.translate(entry_with(a: 1, b: 2))

    expect(result.state).to eq(b: 1, c: 2)
  end

  it "a plain, non-colliding rename is unaffected by the simultaneous rewrite" do
    lineage = Hecks::Ports::Persistence::Lineage.new({ cost: :amount })

    result = lineage.translate(entry_with(cost: 500, other: "untouched"))

    expect(result.state).to eq(amount: 500, other: "untouched")
  end

  it "a rename naming a key absent from this record is a no-op for that key" do
    lineage = Hecks::Ports::Persistence::Lineage.new({ a: :b, b: :a })

    result = lineage.translate(entry_with(a: 1))

    expect(result.state).to eq(b: 1)
  end
end
