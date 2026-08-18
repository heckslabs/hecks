require "spec_helper"

# `GenericDispatch.try`'s own `case shape[:kind]` used to have no `else` —
# `shape_for` names exactly four kinds today (:calls_through/:opens_block/
# :zero_arg/:single_fill), but a fifth added there without a matching `when`
# here would fall through to bare `nil`, which `WordGate#method_missing`'s
# own caller reads as "handled" (anything but NOT_HANDLED counts) — so a
# self-hosted DSL word would silently execute as a no-op rather than raise
# the "not yet implemented" refusal a genuinely unmigrated word already
# gets. `shape_for` cannot itself produce a fifth kind today, so this stubs
# it directly to exercise the backstop past the one gate that would
# otherwise prevent reaching it.
RSpec.describe "GenericDispatch.try, an unrecognized dispatch shape" do
  GenericDispatch = Hecksagain::Bluebook::DSL::GenericDispatch

  it "refuses rather than silently no-opping" do
    allow(GenericDispatch).to receive(:shape_for).and_return({ kind: :teleport })

    expect do
      # `builder` is never touched — the stubbed shape hits the `else`
      # before any real argument is read, same as `try`'s own real
      # `case` never reaching past `shape_for` for an unhandled kind.
      GenericDispatch.try(nil, "Aggregate", "teleport", [], {}, nil, {})
    end.to raise_error(Hecksagain::Runtime::WiringError, /no dispatcher handles shape :teleport/)
  end
end
