require "spec_helper"

RSpec.describe Hecks::AI::TypeResolver do
  describe ".resolve" do
    it "resolves String"  do expect(described_class.resolve("String")).to eq(String) end
    it "resolves Integer" do expect(described_class.resolve("Integer")).to eq(Integer) end
    it "resolves Float"   do expect(described_class.resolve("Float")).to eq(Float) end

    it "resolves list_of to a hash" do
      expect(described_class.resolve("list_of(Item)")).to eq({ list: "Item" })
    end

    it "defaults unknown types to String" do
      expect(described_class.resolve("Bogus")).to eq(String)
    end

    it "defaults nil to String" do
      expect(described_class.resolve(nil)).to eq(String)
    end
  end

  describe ".reference_type?" do
    it "returns truthy for reference_to(...)" do
      expect(described_class.reference_type?("reference_to(Order)")).to be_truthy
    end

    it "returns falsy for plain types" do
      expect(described_class.reference_type?("String")).to be_falsy
    end
  end

  describe ".reference_target" do
    it "extracts the target name" do
      expect(described_class.reference_target("reference_to(Order)")).to eq("Order")
    end

    it "handles quoted targets" do
      expect(described_class.reference_target("reference_to('Order')")).to eq("Order")
    end
  end
end
