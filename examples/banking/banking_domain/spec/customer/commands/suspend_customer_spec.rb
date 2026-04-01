require_relative "../../spec_helper"

RSpec.describe BankingDomain::Customer::Commands::SuspendCustomer do
  describe "attributes" do
    subject(:command) { described_class.new(customer_id: "example") }

    it "has customer_id" do
      expect(command.customer_id).to eq("example")
    end

  end

  describe "event" do
    it "emits SuspendedCustomer" do
      expect(described_class.event_name).to eq("SuspendedCustomer")
    end
  end
end
