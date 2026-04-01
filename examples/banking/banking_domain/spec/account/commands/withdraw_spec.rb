require_relative "../../spec_helper"

RSpec.describe BankingDomain::Account::Commands::Withdraw do
  describe "attributes" do
    subject(:command) { described_class.new(account_id: "example", amount: 1.0) }

    it "has account_id" do
      expect(command.account_id).to eq("example")
    end

    it "has amount" do
      expect(command.amount).to eq(1.0)
    end

  end

  describe "event" do
    it "emits Withdrew" do
      expect(described_class.event_name).to eq("Withdrew")
    end
  end
end
