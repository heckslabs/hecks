require_relative "../../spec_helper"

RSpec.describe BankingDomain::Account::Commands::FlagSuspiciousActivity do
  describe "attributes" do
    subject(:command) { described_class.new(account_id: "example", reason: "example") }

    it "has account_id" do
      expect(command.account_id).to eq("example")
    end

    it "has reason" do
      expect(command.reason).to eq("example")
    end

  end

  describe "event" do
    it "emits FlaggedSuspiciousActivity" do
      expect(described_class.event_name).to eq("FlaggedSuspiciousActivity")
    end
  end
end
