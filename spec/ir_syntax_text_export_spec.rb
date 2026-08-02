require "spec_helper"

# rust/src/bluebook/ir_syntax_text.rs is bin/ir_syntax_text's output — every
# named argument the language declares as kind "text" (language/bluebook/
# syntax.bluebook's Syntax::Argument), projected so assert_text_kwarg
# (parse_blocks.rs) can hold its own callers to the declaration instead of
# trusting every call site by hand.
#
# The kind-generation pattern bin/ir_syntax_flags established, one kind
# further — see that generator's own header for why the reader stays
# hand-written and only the assertion is generated.
#
# Nothing else catches a forgotten regeneration — the Rust build succeeds
# either way, it would just be compiling a stale table.
RSpec.describe "the projected Rust text arguments" do
  it "rust/src/bluebook/ir_syntax_text.rs matches bin/ir_syntax_text's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/ir_syntax_text.rs"))
    current    = `#{File.join(root, 'bin/ir_syntax_text')}`

    expect(checked_in).to eq(current),
                          "rust/src/bluebook/ir_syntax_text.rs is stale — regenerate with " \
                          "`bin/ir_syntax_text > rust/src/bluebook/ir_syntax_text.rs`"
  end
end
