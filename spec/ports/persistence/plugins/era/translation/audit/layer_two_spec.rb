require "hecks"
require "hecks/ports/persistence/plugins/era"

# H5 (docs/audits/2026-08-10-main-bug-audit.md) — a DOTTED-member compute
# (`price.cents`) used to exempt the WHOLE top-level attribute (`price`)
# from Layer 2's cross-execution equivalence gate, because `compute_tops`
# collapsed every compute path down to its first `.`-segment before
# rejecting it from both sides of the comparison. A migration that
# silently nulled or dropped a SIBLING member of the same value object
# (`price.currency`, never touched by the compute at all) produced zero
# violations — exactly the data loss this gate exists to catch.
#
# These specs drive `Audit.layer_two!` directly, with plain Ruby
# declared-rule objects and before/after hashes — no Postgres involved.
# Layer 2 is pure in-process comparison; the SQL-execution half of a
# compute rule is exercised separately in
# spec/adapters/driven/postgres_era/lineage_spec.rb.
RSpec.describe "Layer 2's cross-execution equivalence gate and dotted-member computes" do
  Aggregate = Struct.new(:name) unless defined?(Aggregate)

  def declared_with_compute(from:, to:)
    Hecks::Bluebook::TranslationAggregate.new(
      name:     "Product",
      computes: [Hecks::Bluebook::TranslationCompute.new(from, to, "irrelevant sql")]
    )
  end

  def violations_for(declared, before, after)
    violations = []
    Hecks::Translation::Audit.layer_two!(violations, Aggregate.new("Product"), declared, before, after)
    violations
  end

  it "still exempts a BARE compute's own attribute entirely — a whole-attribute compute has nothing else to check" do
    declared = declared_with_compute(from: "price_cents", to: "price_dollars")
    before = { "p1" => { "price_cents" => { "value" => 1250 } } }
    after = { "p1" => { "price_dollars" => { "value" => 12.5 } } }

    expect(violations_for(declared, before, after)).to be_empty
  end

  it "no longer exempts a SIBLING member of a dotted compute's own value object" do
    declared = declared_with_compute(from: "price.cents", to: "price.cents")
    before = { "p1" => { "price" => { "cents" => 100, "currency" => "USD" } } }

    # the compute legitimately recomputes "price.cents" — that alone must
    # not be flagged, the SQL is its only implementation
    recomputed_only = { "p1" => { "price" => { "cents" => 1, "currency" => "USD" } } }
    expect(violations_for(declared, before, recomputed_only)).to be_empty

    # but a migration that silently nulls the SIBLING member the compute
    # never touches is real, undeclared data loss — this is the bug: it
    # used to produce zero violations because the whole "price" top-level
    # key was exempted along with "price.cents"
    sibling_nulled = { "p1" => { "price" => { "cents" => 1, "currency" => nil } } }
    violations = violations_for(declared, before, sibling_nulled)

    expect(violations.size).to eq(1)
    expect(violations.first).to include("Product#p1")
    expect(violations.first).to include("price")
  end

  it "no longer exempts a sibling member when the dotted compute's from/to paths differ" do
    declared = declared_with_compute(from: "price.cents", to: "price.rounded_cents")
    before = { "p1" => { "price" => { "cents" => 100, "currency" => "USD" } } }
    sibling_dropped = { "p1" => { "price" => { "rounded_cents" => 100 } } } # "currency" vanished, unexplained

    violations = violations_for(declared, before, sibling_dropped)

    expect(violations.size).to eq(1)
    expect(violations.first).to include("Product#p1")
  end
end
