require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# M27 (docs/audits/2026-08-10-main-bug-audit.md,
# docs/audits/2026-08-11-bug-triage.md) — `Lineage#translate` applied
# `@renames` SEQUENTIALLY, in-place, against the same hash it was still
# reading from: `state[new_name] = state.delete(old_name)` per rule, one
# rule at a time. A SWAP (`rename :a, to: :b` alongside `rename :b,
# to: :a`) on `{a: 1, b: 2}` used to produce `{a: 1}` — the first rule
# wrote over `:b`'s real value before the second rule ever got to read
# it, so `b`'s original value (2) vanished outright. Layer 2 audits the
# COMPILED SQL against this exact reference transform (`layer_two.rb`),
# so the bug wasn't merely wrong — it was self-consistent: the SQL and
# this Ruby reference AGREED on the lossy answer, and a mint holding a
# genuine data-losing rename sailed through silently.
#
# The fix computes the full old-name -> value mapping FIRST (a
# snapshot untouched by either pass), removes every old key, and only
# THEN writes every new key — so a rename never reads a key this same
# pass already wrote to, and a swap or a longer chain applies as one
# simultaneous permutation rather than a sequence of edits each
# stepping on the last.
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
    # Simultaneous semantics: this is a permutation computed against the
    # state as it stood BEFORE the edge ran, not a sequential replay —
    # "b" no longer exists as a source by the time "b -> c" would apply
    # sequentially, but it's still evaluated against the ORIGINAL
    # snapshot, so the ORIGINAL b's value (2) is what ends up at c only
    # if a rule renamed b (it does here), not a's value laundered
    # through it.
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
