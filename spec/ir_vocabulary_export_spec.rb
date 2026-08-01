require "spec_helper"

# rust/src/bluebook/ir_vocabulary.rs is bin/ir_vocabulary's output — Rust SOURCE
# projected from the language's own `Vocabulary` closed sets, checked in because
# Rust cannot run the Ruby DSL to read them (the same reason operators.json and
# mutation_ops.json are checked in, one step further along: those export a table
# as data, this exports the type declarations themselves).
#
# Nothing else catches a forgotten regeneration — the Rust build succeeds either
# way, it would just be compiling a stale copy of a set the language has since
# changed, which is exactly the drift that made these worth projecting (eleven
# MutationOp variants against four admitted, a WhereOp the language never
# declared). So this holds the checked-in file equal to what the script produces
# right now.
RSpec.describe "the projected Rust vocabulary" do
  it "rust/src/bluebook/ir_vocabulary.rs matches bin/ir_vocabulary's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/ir_vocabulary.rs"))
    current    = `#{File.join(root, 'bin/ir_vocabulary')}`

    expect(checked_in).to eq(current),
                          "rust/src/bluebook/ir_vocabulary.rs is stale — regenerate with " \
                          "`bin/ir_vocabulary > rust/src/bluebook/ir_vocabulary.rs`"
  end
end
