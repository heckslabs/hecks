require_relative "../spec_helper"

RSpec.describe BankingDomain::Transfer do
  describe "creating a Transfer" do
    subject(:transfer) { described_class.new(
          from_account_id: "ref-id-123",
          to_account_id: "ref-id-123",
          amount: 1.0,
          status: "example",
          memo: "example"
        ) }

    it "assigns an id" do
      expect(transfer.id).not_to be_nil
    end

    it "sets from_account_id" do
      expect(transfer.from_account_id).to eq("ref-id-123")
    end

    it "sets to_account_id" do
      expect(transfer.to_account_id).to eq("ref-id-123")
    end

    it "sets amount" do
      expect(transfer.amount).to eq(1.0)
    end

    it "sets status" do
      expect(transfer.status).to eq("example")
    end

    it "sets memo" do
      expect(transfer.memo).to eq("example")
    end
  end

  describe "amount validation" do
    it "rejects nil amount" do
      expect {
        described_class.new(
          from_account_id: "ref-id-123",
          to_account_id: "ref-id-123",
          amount: nil,
          status: "example",
          memo: "example"
        )
      }.to raise_error(BankingDomain::ValidationError, /amount/)
    end
  end

  describe "identity" do
    it "two Transfers with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          from_account_id: "ref-id-123",
          to_account_id: "ref-id-123",
          amount: 1.0,
          status: "example",
          memo: "example",
          id: id
        )
      b = described_class.new(
          from_account_id: "ref-id-123",
          to_account_id: "ref-id-123",
          amount: 1.0,
          status: "example",
          memo: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Transfers with different ids are not equal" do
      a = described_class.new(
          from_account_id: "ref-id-123",
          to_account_id: "ref-id-123",
          amount: 1.0,
          status: "example",
          memo: "example"
        )
      b = described_class.new(
          from_account_id: "ref-id-123",
          to_account_id: "ref-id-123",
          amount: 1.0,
          status: "example",
          memo: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
