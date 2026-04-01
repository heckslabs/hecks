require "spec_helper"

RSpec.describe BlueBook::Grammar do
  describe ".parse" do
    it "parses bare commands" do
      result = described_class.parse("describe")
      expect(result).to eq(target: nil, method: "describe", args: [], kwargs: {})
    end

    it "parses aggregate-only input" do
      result = described_class.parse("Pizza")
      expect(result).to eq(target: "Pizza", method: nil, args: [], kwargs: {})
    end

    it "parses handle method with symbol arg" do
      result = described_class.parse("Pizza.attr :name, String")
      expect(result[:target]).to eq("Pizza")
      expect(result[:method]).to eq("attr")
      expect(result[:args]).to include(:name)
      expect(result[:args]).to include(String)
    end

    it "parses reference_to argument" do
      result = described_class.parse('Pizza.attr :order_id, reference_to("Order")')
      expect(result[:target]).to eq("Pizza")
      expect(result[:method]).to eq("attr")
      expect(result[:args]).to include(:order_id)
      expect(result[:args]).to include({ reference: "Order" })
    end

    it "parses list_of argument" do
      result = described_class.parse('Pizza.attr :items, list_of("LineItem")')
      expect(result[:args]).to include({ list: "LineItem" })
    end

    it "rejects empty input" do
      result = described_class.parse("")
      expect(result[:error]).to eq("Empty command")
    end

    it "rejects blocked methods" do
      %w[send eval instance_eval system exec fork require load].each do |blocked|
        result = described_class.parse("Pizza.#{blocked}")
        expect(result[:error]).to include("Unknown method"), "expected #{blocked} to be blocked"
      end
    end

    it "rejects non-PascalCase targets" do
      result = described_class.parse("file.read")
      expect(result[:error]).to include("Unknown command")
    end

    it "parses keyword arguments" do
      result = described_class.parse('Pizza.validation :name, presence: true')
      expect(result[:kwargs]).to eq(presence: true)
    end
  end
end
