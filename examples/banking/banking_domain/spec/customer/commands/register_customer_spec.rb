require_relative "../../spec_helper"

RSpec.describe BankingDomain::Customer::Commands::RegisterCustomer do
  describe "attributes" do
    subject(:command) { described_class.new(name: "example", email: "example") }

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has email" do
      expect(command.email).to eq("example")
    end

  end

  describe "event" do
    it "emits RegisteredCustomer" do
      expect(described_class.event_name).to eq("RegisteredCustomer")
    end
  end
end
