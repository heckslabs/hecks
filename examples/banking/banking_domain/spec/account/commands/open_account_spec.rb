require_relative "../../spec_helper"

RSpec.describe BankingDomain::Account::Commands::OpenAccount do
  describe "attributes" do
    subject(:command) { described_class.new(
          customer_id: "example",
          account_type: "example",
          daily_limit: 1.0
        ) }

    it "has customer_id" do
      expect(command.customer_id).to eq("example")
    end

    it "has account_type" do
      expect(command.account_type).to eq("example")
    end

    it "has daily_limit" do
      expect(command.daily_limit).to eq(1.0)
    end

  end

  describe "event" do
    it "emits OpenedAccount" do
      expect(described_class.event_name).to eq("OpenedAccount")
    end
  end
end
