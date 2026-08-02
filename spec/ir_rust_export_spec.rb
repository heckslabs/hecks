require "spec_helper"

# rust/src/bluebook/projected/*.rs is bin/ir_rust's output — a whole DOMAIN as
# Rust values of the structs `bin/ir_structs` projects from the language.
#
# The third and last rung of the projection. `bin/ir_vocabulary` projects the
# closed sets, `bin/ir_structs` the shapes those sets sit in, and this the
# domains themselves — so a booted Rust runtime needs neither Ruby-produced JSON
# nor a `.bluebook` parse to know what a domain is.
#
# Checked in for the same reason the other two are: Rust cannot run the Ruby DSL,
# so it compiles against a copy. A copy nothing compares is a copy that drifts,
# and the Rust build succeeds against a stale one exactly as happily as a fresh
# one.
#
# TWO CHECKS, AND THE SECOND IS THE ONE THAT MATTERS. This spec holds the file
# equal to the generator's current output — a forgotten regeneration goes red
# rather than compiling a stale domain. The other lives in Rust
# (`bluebook::projected::tests`) and flattens the PROJECTED domain back through
# `ir_json::domain_to_value` to diff it against Ruby's frozen IR, which is
# `bin/parity`'s byte-for-byte contract pointed at the projection instead of at
# the parser. Determinism is not correctness; that one is correctness.
RSpec.describe "the projected Rust domains" do
  # EVERY CHAPTER RUST CAN HOLD. Pizzas alone exercised mutations, an append,
  # invariants, a closed set and a lifecycle — and none of the paths carrying
  # entities, sagas, dispatch bindings or read models. Projecting the rest found
  # three inversion bugs in one sitting, all of them the encoding-loss family
  # this codebase already names.
  #
  # `Reflex` used to be absent on purpose: it declares every query option the
  # language holds, and Rust's `Query`/`ReadModel` structs carried none of
  # them, so there was nowhere to project them to. Once both grew the eight
  # specification options, Reflex joined the rest — proving the gap closed the
  # same way every other claim here is proven, by projecting the chapter that
  # exercises it and diffing against Ruby's own frozen IR.
  PROJECTED = {
    "Banking"    => ["examples/banking/bluebook/banking.bluebook",              "banking"],
    "Expression" => ["lib/hecksagain/grammar/expression.bluebook",              "expression"],
    "Pizzas"     => ["examples/pizzas/bluebook/pizzas.bluebook",                "pizzas"],
    "Reflex"     => ["spec/fixtures/reflex.bluebook",                          "reflex"],
    "TillRoom"   => ["spec/fixtures/till.bluebook",                             "till_room"],
    "Wire"       => ["spec/fixtures/settlement.bluebook",                       "wire"]
  }.freeze

  PROJECTED.each do |name, (source, stem)|
    output = "rust/src/bluebook/projected/#{stem}.rs"

    it "#{output} matches bin/ir_rust's current output" do
      root       = InMemoryDomain::ROOT
      checked_in = File.read(File.join(root, output))
      current    = `#{File.join(root, 'bin/ir_rust')} #{File.join(root, source)} 2>/dev/null`

      expect(current).not_to be_empty, "bin/ir_rust produced nothing for #{name}"
      expect(checked_in).to eq(current),
                            "#{output} is stale — regenerate with " \
                            "`bin/ir_rust #{source} > #{output}`"
    end
  end
end
