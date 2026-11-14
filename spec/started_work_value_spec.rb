require "spec_helper"
require "hecks/hecks/adapters/started_work"

# A record read for a field it does not carry answers nothing, whether it is a hash or a struct,
# so a reader that asks every record for the same fields never raises on an older shape.
RSpec.describe Hecks::Adapters::StartedWork do
  let(:struct) { Struct.new(:status, :work).new("started", "item-a") }

  it "reads a member of a struct" do
    expect(described_class.value(struct, :work)).to eq("item-a")
  end

  it "answers nil for a struct that has no such member" do
    expect(described_class.value(struct, :session)).to be_nil
  end

  it "answers nil for a hash with no such key" do
    expect(described_class.value({ status: "started" }, :session)).to be_nil
  end

  it "reads a key of a hash and unwraps a value object" do
    expect(described_class.value({ work: Struct.new(:value).new("item-b") }, :work)).to eq("item-b")
  end
end
