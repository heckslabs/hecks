require "spec_helper"

# Pins the `else` backstop in `GenericDispatch.try`: an unhandled shape kind must raise, not
# return nil, which `WordGate#method_missing` reads as "handled". `shape_for` is stubbed
# because it cannot produce an unknown kind itself.
RSpec.describe "GenericDispatch.try, an unrecognized dispatch shape" do
  GenericDispatch = Hecks::Bluebook::DSL::GenericDispatch

  it "refuses rather than silently no-opping" do
    allow(GenericDispatch).to receive(:shape_for).and_return({ kind: :teleport })

    expect do
      # `builder` is never touched: the stubbed shape hits the `else` first.
      GenericDispatch.try(nil, "Aggregate", "teleport", [], {}, nil, {})
    end.to raise_error(Hecks::Runtime::WiringError, /no dispatcher handles shape :teleport/)
  end
end
