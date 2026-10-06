require "spec_helper"

# Value-object-like doubles stand in for `Runtime::Value`, which requires the
# renderer, so it is matched by `respond_to?(:to_h)` and cannot be named here.
RSpec.describe "Rendering.describe" do
  SingleField = Struct.new(:cents) do
    def to_h = { cents: cents }
  end

  MultiField = Struct.new(:given, :family) do
    def to_h = { given: given, family: family }
  end

  it "unwraps a single-field wrapper to its bare scalar, described recursively" do
    expect(Hecks::Rendering.describe(SingleField.new(500))).to eq("500")
  end

  it "renders a multi-field wrapper as its fields' JSON" do
    expect(Hecks::Rendering.describe(MultiField.new("Annie", "Easley")))
      .to eq('{"given":"Annie","family":"Easley"}')
  end

  it "still renders a bare Hash/Array via JSON, not the value-object branch", :aggregate_failures do
    expect(Hecks::Rendering.describe({ cents: 100 })).to eq('{"cents":100}')
    expect(Hecks::Rendering.describe([1, 2])).to eq("[1,2]")
  end

  it "renders nil and a plain scalar exactly as before", :aggregate_failures do
    expect(Hecks::Rendering.describe(nil)).to eq("nil")
    expect(Hecks::Rendering.describe(42)).to eq("42")
    expect(Hecks::Rendering.describe("plain")).to eq('"plain"')
  end
end
