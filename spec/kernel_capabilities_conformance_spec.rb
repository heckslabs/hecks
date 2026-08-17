require "spec_helper"
require "hecksagain/grammar"

# `bin/project_kernel_capabilities` generates `rust/src/kernel/
# attribute_shapes/mod.rs` and `rust/src/kernel/expression_operators/
# mod.rs` from two live Ruby ground truths — `Coercion::SHAPES` and
# `Grammar.admitted_operators`'s own `category` field — but nothing held
# the checked-in generated files to those ground truths the way
# spec/vocabulary_conformance_spec.rb holds other tables to their own
# live constants. Item #8, whole-project table-unification survey:
# confirmed CURRENT (zero drift) when investigated, but the investigation
# itself found no automated gate — exactly the same shape item #2's real,
# 39-vs-42-entry refusal-wording drift went unnoticed for. This closes
# that gap the same way: read the checked-in file's own `pub mod <name>;`
# roster (the one line per capability this generator's own `emit_mod`
# writes, in Ruby's own current order) and hold it to the live Ruby
# table, both directions.
RSpec.describe "kernel capability tables (bin/project_kernel_capabilities)" do
  def self.pub_mod_names(path)
    File.readlines(File.join(InMemoryDomain::ROOT, path))
        .filter_map { |line| line[/^pub mod (\w+);/, 1] }
  end

  ATTRIBUTE_SHAPE_NAMES = pub_mod_names("rust/src/kernel/attribute_shapes/mod.rs")
  OPERATOR_CATEGORY_NAMES = pub_mod_names("rust/src/kernel/expression_operators/mod.rs")

  it "generates attribute_shapes/mod.rs from the SAME order Coercion::SHAPES declares" do
    expect(ATTRIBUTE_SHAPE_NAMES).to eq(Hecksagain::Runtime::Value::Coercion::SHAPES.map(&:to_s)),
                                     "rust/src/kernel/attribute_shapes/mod.rs is stale relative to " \
                                     "Coercion::SHAPES — run bin/project_kernel_capabilities"
  end

  it "generates expression_operators/mod.rs from the SAME first-appearance category order Grammar.admitted_operators declares" do
    live = Hecksagain::Grammar.admitted_operators.map { |op| op[:category].to_s }.uniq
    expect(OPERATOR_CATEGORY_NAMES).to eq(live),
                                       "rust/src/kernel/expression_operators/mod.rs is stale relative to " \
                                       "Grammar.admitted_operators — run bin/project_kernel_capabilities"
  end

  # A GENERATED mod.rs is dead weight without a hand-written file for
  # each `pub mod` line to resolve — the SAME "unresolved module" gate
  # this generator's own header describes bin/rust_kernel_coverage
  # checking mechanically, held here too so this spec alone (without
  # needing a Rust toolchain) already catches the cheap half of it.
  it "has a hand-written file for every attribute shape it names" do
    missing = ATTRIBUTE_SHAPE_NAMES.reject { |name| File.exist?(File.join(InMemoryDomain::ROOT, "rust/src/kernel/attribute_shapes/#{name}.rs")) }
    expect(missing).to be_empty, "attribute_shapes/mod.rs names #{missing.inspect} with no matching hand-written file"
  end

  it "has a hand-written file for every expression-operator category it names" do
    missing = OPERATOR_CATEGORY_NAMES.reject { |name| File.exist?(File.join(InMemoryDomain::ROOT, "rust/src/kernel/expression_operators/#{name}.rs")) }
    expect(missing).to be_empty, "expression_operators/mod.rs names #{missing.inspect} with no matching hand-written file"
  end
end
