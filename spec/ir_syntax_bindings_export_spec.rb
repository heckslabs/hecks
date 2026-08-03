require "spec_helper"

# rust/src/bluebook/ir_syntax_bindings.rs is bin/ir_syntax_bindings's output —
# every (keyword, context) pair's own argument-binding shape, projected from
# the language's own declared syntax (Syntax::Keyword, Syntax::Argument —
# language/bluebook/syntax.bluebook).
#
# The next rung after bin/ir_dispatch_words (word recognition — which word
# opens which category). This one is what a word's own ARGUMENTS mean once it
# has been recognized — kind/at/named/required/fills, plus the pairs-shape and
# op-selection columns M1 of the generic-bluebook-reader arc added. What
# happens with a binding once it is produced (does it set a field directly, or
# build a new compound appended to a list) is generated too (`append_to`); the
# generic binder module (rust/src/bluebook/generic_bind.rs) is what turns a
# binding into an actual field on an actual struct — that part stays
# hand-written by necessity (Rust has no reflection to set a named field
# generically), same as ever.
#
# Nothing else catches a forgotten regeneration — the Rust build succeeds
# either way, it would just be compiling a stale binding table.
RSpec.describe "the projected Rust syntax bindings" do
  it "rust/src/bluebook/ir_syntax_bindings.rs matches bin/ir_syntax_bindings's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/ir_syntax_bindings.rs"))
    current    = `#{File.join(root, 'bin/ir_syntax_bindings')}`

    expect(checked_in).to eq(current),
                          "rust/src/bluebook/ir_syntax_bindings.rs is stale — regenerate with " \
                          "`bin/ir_syntax_bindings > rust/src/bluebook/ir_syntax_bindings.rs`"
  end
end
