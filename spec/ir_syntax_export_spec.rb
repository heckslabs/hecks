require "spec_helper"

# rust/src/bluebook/ir_syntax.rs is bin/ir_syntax's output — every word the
# language admits directly in an aggregate's own body, block-opening or not,
# projected from the language's own `Syntax::Keyword` declaration
# (language/bluebook/syntax.bluebook).
#
# Nothing else catches a forgotten regeneration — the Rust build succeeds
# either way, it would just be compiling a stale copy of the list the language
# has since changed, which is exactly the drift that made this worth
# projecting: the hand-written copy this replaced carried five words
# (`view`, `rule`, `factory`, `create`, `invariant`) the language never admits
# at aggregate-body level, each treated as a KNOWN keyword and let straight
# through the check meant to catch exactly that.
RSpec.describe "the projected Rust syntax" do
  it "rust/src/bluebook/ir_syntax.rs matches bin/ir_syntax's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/ir_syntax.rs"))
    current    = `#{File.join(root, 'bin/ir_syntax')}`

    expect(checked_in).to eq(current),
                          "rust/src/bluebook/ir_syntax.rs is stale — regenerate with " \
                          "`bin/ir_syntax > rust/src/bluebook/ir_syntax.rs`"
  end
end
