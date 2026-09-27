require "spec_helper"
require "hecks/grammar"

# Holds the generated kernel/attribute_shapes and kernel/expression_operators mod.rs
# rosters to `Coercion::SHAPES` and `Grammar.admitted_operators`, both directions.
RSpec.describe "kernel capability tables (bin/project_kernel_capabilities)" do
  def self.pub_mod_names(path)
    File.readlines(File.join(InMemoryDomain::ROOT, path))
        .filter_map { |line| line[/^pub mod (\w+);/, 1] }
  end

  ATTRIBUTE_SHAPE_NAMES = pub_mod_names("rust/src/kernel/attribute_shapes/mod.rs")
  OPERATOR_CATEGORY_NAMES = pub_mod_names("rust/src/kernel/expression_operators/mod.rs")

  it "generates attribute_shapes/mod.rs from the SAME order Coercion::SHAPES declares" do
    expect(ATTRIBUTE_SHAPE_NAMES).to eq(Hecks::Runtime::Value::Coercion::SHAPES.map(&:to_s)),
                                     "rust/src/kernel/attribute_shapes/mod.rs is stale relative to " \
                                     "Coercion::SHAPES — run bin/project_kernel_capabilities"
  end

  it "generates expression_operators/mod.rs from the SAME first-appearance category order Grammar.admitted_operators declares" do
    live = Hecks::Grammar.admitted_operators.map { |op| op[:category].to_s }.uniq
    expect(OPERATOR_CATEGORY_NAMES).to eq(live),
                                       "rust/src/kernel/expression_operators/mod.rs is stale relative to " \
                                       "Grammar.admitted_operators — run bin/project_kernel_capabilities"
  end

  # A `pub mod` line with no hand-written file is an unresolved module; this catches
  # that without a Rust toolchain.
  it "has a hand-written file for every attribute shape it names" do
    missing = ATTRIBUTE_SHAPE_NAMES.reject { |name| File.exist?(File.join(InMemoryDomain::ROOT, "rust/src/kernel/attribute_shapes/#{name}.rs")) }
    expect(missing).to be_empty, "attribute_shapes/mod.rs names #{missing.inspect} with no matching hand-written file"
  end

  it "has a hand-written file for every expression-operator category it names" do
    missing = OPERATOR_CATEGORY_NAMES.reject { |name| File.exist?(File.join(InMemoryDomain::ROOT, "rust/src/kernel/expression_operators/#{name}.rs")) }
    expect(missing).to be_empty, "expression_operators/mod.rs names #{missing.inspect} with no matching hand-written file"
  end
end
