require_relative "../../spec_helper"

RSpec.describe BankingDomain::Transfer::Commands::RejectTransfer do
  describe "attributes" do
    subject(:command) { described_class.new(transfer_id: "example") }

    it "has transfer_id" do
      expect(command.transfer_id).to eq("example")
    end

  end

  describe "event" do
    it "emits RejectedTransfer" do
      expect(described_class.event_name).to eq("RejectedTransfer")
    end
  end
end
