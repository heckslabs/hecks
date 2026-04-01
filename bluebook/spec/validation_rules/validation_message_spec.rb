require "spec_helper"

RSpec.describe Hecks::ValidationRules::ValidationMessage do
  subject(:msg) { described_class.new("Name is blank", hint: "Add: attribute :name, String") }

  describe "#to_s" do
    it "returns just the message" do
      expect(msg.to_s).to eq("Name is blank")
    end
  end

  describe "#hint" do
    it "returns the fix hint" do
      expect(msg.hint).to eq("Add: attribute :name, String")
    end

    it "is nil when not provided" do
      plain = described_class.new("No hint")
      expect(plain.hint).to be_nil
    end
  end

  describe "#to_h" do
    it "includes message and hint" do
      expect(msg.to_h).to eq({ message: "Name is blank", hint: "Add: attribute :name, String" })
    end

    it "omits hint when nil" do
      plain = described_class.new("No hint")
      expect(plain.to_h).to eq({ message: "No hint" })
    end
  end

  describe "string compatibility" do
    it "works with include?" do
      expect(msg.include?("blank")).to be true
    end

    it "searches hint via include?" do
      expect(msg.include?("attribute :name")).to be true
    end

    it "matches regex via =~" do
      expect(msg =~ /blank/).to be_truthy
    end

    it "compares equal to its message string" do
      expect(msg).to eq("Name is blank")
    end

    it "works with downcase" do
      expect(msg.downcase).to include("name is blank")
    end

    it "works with start_with?" do
      expect(msg.start_with?("Name")).to be true
    end
  end
end
