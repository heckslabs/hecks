require_relative "../../spec_helper"

RSpec.describe BankingDomain::Account::Commands::CloseAccount do
  describe "attributes" do
    subject(:command) { described_class.new(account_id: "example") }

    it "has account_id" do
      expect(command.account_id).to eq("example")
    end

  end

  describe "event" do
    it "emits ClosedAccount" do
      expect(described_class.event_name).to eq("ClosedAccount")
    end
  end
end
