require "spec_helper"

RSpec.describe Hecks::DomainModel::Behavior::Command do
  subject(:command) do
    described_class.new(name: "CreatePizza", attributes: [])
  end

  describe "#inferred_event_name" do
    it "converts Create to Created" do
      cmd = described_class.new(name: "CreatePizza", attributes: [])
      expect(cmd.inferred_event_name).to eq("CreatedPizza")
    end

    it "converts Add to Added" do
      cmd = described_class.new(name: "AddTopping", attributes: [])
      expect(cmd.inferred_event_name).to eq("AddedTopping")
    end

    it "converts Place to Placed" do
      cmd = described_class.new(name: "PlaceOrder", attributes: [])
      expect(cmd.inferred_event_name).to eq("PlacedOrder")
    end
  end

  describe "#event_names" do
    context "when emits is nil (default)" do
      it "returns array with inferred event name" do
        cmd = described_class.new(name: "CreatePizza", attributes: [])
        expect(cmd.event_names).to eq(["CreatedPizza"])
      end
    end

    context "when emits is a single string" do
      it "returns array with that name" do
        cmd = described_class.new(name: "CreatePizza", attributes: [], emits: "PizzaCreated")
        expect(cmd.event_names).to eq(["PizzaCreated"])
      end
    end

    context "when emits is an array of names" do
      it "returns all names" do
        cmd = described_class.new(name: "CreatePizza", attributes: [], emits: ["PizzaCreated", "MenuUpdated"])
        expect(cmd.event_names).to eq(["PizzaCreated", "MenuUpdated"])
      end
    end
  end

  describe "#emits" do
    it "is nil by default" do
      cmd = described_class.new(name: "CreatePizza", attributes: [])
      expect(cmd.emits).to be_nil
    end

    it "stores a single name string" do
      cmd = described_class.new(name: "CreatePizza", attributes: [], emits: "PizzaCreated")
      expect(cmd.emits).to eq("PizzaCreated")
    end

    it "stores an array for multiple names" do
      cmd = described_class.new(name: "CreatePizza", attributes: [], emits: ["PizzaCreated", "MenuUpdated"])
      expect(cmd.emits).to eq(["PizzaCreated", "MenuUpdated"])
    end
  end
end
