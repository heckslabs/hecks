require "spec_helper"

# rust/src/bluebook/ir_syntax_number.rs is bin/ir_syntax_number's output —
# every named argument the language declares as kind "number"
# (language/bluebook/syntax.bluebook's Syntax::Argument), projected so
# assert_number_kwarg (parse_blocks.rs) can hold its own callers to the
# declaration instead of trusting every call site by hand.
#
# The kind-generation pattern bin/ir_syntax_flags established, one kind
# further — see that generator's own header for why the reader stays
# hand-written and only the assertion is generated.
#
# Nothing else catches a forgotten regeneration — the Rust build succeeds
# either way, it would just be compiling a stale table.
RSpec.describe "the projected Rust number arguments" do
  it "rust/src/bluebook/ir_syntax_number.rs matches bin/ir_syntax_number's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/ir_syntax_number.rs"))
    current    = `#{File.join(root, 'bin/ir_syntax_number')}`

    expect(checked_in).to eq(current),
                          "rust/src/bluebook/ir_syntax_number.rs is stale — regenerate with " \
                          "`bin/ir_syntax_number > rust/src/bluebook/ir_syntax_number.rs`"
  end
end
