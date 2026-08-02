require "spec_helper"

# rust/src/bluebook/ir_syntax_flags.rs is bin/ir_syntax_flags's output — every
# named argument the language declares as kind "flag" (language/bluebook/
# syntax.bluebook's Syntax::Argument), projected so parse_flag_kwarg
# (parse_blocks.rs) can assert its own caller against the declaration instead
# of trusting every call site by hand.
#
# The first slice of ARGUMENT generation, not just word recognition — smaller
# than a real generated reader (parse_flag_kwarg itself stays hand-written),
# but load-bearing: a future flag-kind argument wired to the wrong reader, or
# a reader pointed at a kwarg that isn't a flag, panics instead of silently
# mis-parsing.
#
# Nothing else catches a forgotten regeneration — the Rust build succeeds
# either way, it would just be compiling a stale table.
RSpec.describe "the projected Rust flag arguments" do
  it "rust/src/bluebook/ir_syntax_flags.rs matches bin/ir_syntax_flags's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/ir_syntax_flags.rs"))
    current    = `#{File.join(root, 'bin/ir_syntax_flags')}`

    expect(checked_in).to eq(current),
                          "rust/src/bluebook/ir_syntax_flags.rs is stale — regenerate with " \
                          "`bin/ir_syntax_flags > rust/src/bluebook/ir_syntax_flags.rs`"
  end
end
