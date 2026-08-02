require "spec_helper"

# rust/src/bluebook/ir_dispatch_words.rs is bin/ir_dispatch_words's output —
# which word opens which category, per context, projected from the language's
# own `Syntax::Keyword` declaration (language/bluebook/syntax.bluebook, rows
# where `opens` is not empty).
#
# The first rung of projecting the PARSER rather than its shapes. `parser.rs`'s
# `dispatch_block` used to hand-maintain the four-word Bluebook-context list ;
# `parse_aggregate` its own five-word Aggregate-context one, three of them
# checked with no word-boundary guard at all. Only the RECOGNITION moved —
# which word a line starts with, and which category it opens. What happens
# once a category opens stays hand-written in each function's own match arms.
#
# Nothing else catches a forgotten regeneration — the Rust build succeeds
# either way, it would just be compiling a stale word list.
RSpec.describe "the projected Rust dispatch words" do
  it "rust/src/bluebook/ir_dispatch_words.rs matches bin/ir_dispatch_words's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/ir_dispatch_words.rs"))
    current    = `#{File.join(root, 'bin/ir_dispatch_words')}`

    expect(checked_in).to eq(current),
                          "rust/src/bluebook/ir_dispatch_words.rs is stale — regenerate with " \
                          "`bin/ir_dispatch_words > rust/src/bluebook/ir_dispatch_words.rs`"
  end
end
