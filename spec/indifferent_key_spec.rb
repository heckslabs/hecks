require_relative "../lib/hecks/indifferent_key"

RSpec.describe Hecks::IndifferentKey do
  it "reads a Symbol-keyed hash by either spelling" do
    expect(described_class.read({ era: "a1" }, "era")).to eq("a1")
  end

  it "reads a String-keyed hash by either spelling" do
    expect(described_class.read({ "era" => "a1" }, :era)).to eq("a1")
  end

  it "prefers the spelling it was given when both are held" do
    expect(described_class.read({ "args" => false, args: { "a" => 1 } }, "args")).to be(false)
  end

  it "answers a held false rather than treating it as absent" do
    expect(described_class.read({ "enabled" => false }, :enabled)).to be(false)
  end

  it "answers nil when neither spelling is present" do
    expect(described_class.read({}, :era)).to be_nil
  end
end
