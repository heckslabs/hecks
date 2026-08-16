require "spec_helper"

# `Rendering.describe` left a `Hecksagain::Runtime::Value` with no case,
# falling straight through to Ruby's own `#inspect` and leaking a raw
# object pointer ("#<Hecksagain::Runtime::Value:0x...>") into an otherwise
# correct domain refusal message (an arithmetic op's own amount/current, an
# Admissibility current, ...). Duck-typed on `respond_to?(:to_h)` rather
# than naming `Runtime::Value` directly — that class itself requires this
# file, so naming it here would be circular. These doubles stand in for it:
# a single-field wrapper (the common VO shape — an amount, an id, a
# lifecycle field) unwraps to its bare scalar; a genuinely multi-field
# value renders as its fields' JSON, same as a bare Hash already does.
RSpec.describe "Rendering.describe" do
  SingleField = Struct.new(:cents) do
    def to_h = { cents: cents }
  end

  MultiField = Struct.new(:given, :family) do
    def to_h = { given: given, family: family }
  end

  it "unwraps a single-field wrapper to its bare scalar, described recursively" do
    expect(Hecksagain::Rendering.describe(SingleField.new(500))).to eq("500")
  end

  it "renders a multi-field wrapper as its fields' JSON" do
    expect(Hecksagain::Rendering.describe(MultiField.new("Annie", "Easley")))
      .to eq('{"given":"Annie","family":"Easley"}')
  end

  it "still renders a bare Hash/Array via JSON, not the value-object branch" do
    expect(Hecksagain::Rendering.describe({ cents: 100 })).to eq('{"cents":100}')
    expect(Hecksagain::Rendering.describe([1, 2])).to eq("[1,2]")
  end

  it "renders nil and a plain scalar exactly as before" do
    expect(Hecksagain::Rendering.describe(nil)).to eq("nil")
    expect(Hecksagain::Rendering.describe(42)).to eq("42")
    expect(Hecksagain::Rendering.describe("plain")).to eq('"plain"')
  end
end
