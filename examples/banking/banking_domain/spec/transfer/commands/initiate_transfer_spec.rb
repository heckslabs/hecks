require_relative "../../spec_helper"

RSpec.describe BankingDomain::Transfer::Commands::InitiateTransfer do
  describe "attributes" do
    subject(:command) { described_class.new(
          from_account_id: "example",
          to_account_id: "example",
          amount: 1.0,
          memo: "example"
        ) }

    it "has from_account_id" do
      expect(command.from_account_id).to eq("example")
    end

    it "has to_account_id" do
      expect(command.to_account_id).to eq("example")
    end

    it "has amount" do
      expect(command.amount).to eq(1.0)
    end

    it "has memo" do
      expect(command.memo).to eq("example")
    end

  end

  describe "event" do
    it "emits InitiatedTransfer" do
      expect(described_class.event_name).to eq("InitiatedTransfer")
    end
  end
end
