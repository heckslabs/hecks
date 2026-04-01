require_relative "../../spec_helper"

RSpec.describe BankingDomain::Customer::Commands::NotifyCustomer do
  describe "attributes" do
    subject(:command) { described_class.new(customer_id: "example", message: "example") }

    it "has customer_id" do
      expect(command.customer_id).to eq("example")
    end

    it "has message" do
      expect(command.message).to eq("example")
    end

  end

  describe "event" do
    it "emits NotifiedCustomer" do
      expect(described_class.event_name).to eq("NotifiedCustomer")
    end
  end
end
