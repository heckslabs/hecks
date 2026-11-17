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

  describe "on a runtime record whose attribute is named like its accessor" do
    let(:record) do
      state = { state: Struct.new(:value).new("completed"), commit: "abc" }
      aggregate = double(hecks_name: "Run", identity_heads: [], identified_by: nil, attribute: nil)
      Hecks::Runtime::Instance.new(aggregate: aggregate, id: "1", state: state, hydrate: false)
    end

    it "reads the attribute named state, not the record's whole state" do
      expect(described_class.value(record, :state)).to eq("completed")
    end

    it "reads an attribute the record has no accessor for" do
      expect(described_class.value(record, :commit)).to eq("abc")
    end
  end
end
