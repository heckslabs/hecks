require_relative "../spec_helper"

RSpec.describe BankingDomain::Account do
  describe "creating a Account" do
    subject(:account) { described_class.new(
          customer_id: "ref-id-123",
          balance: 1.0,
          account_type: "example",
          daily_limit: 1.0,
          status: "example",
          ledger: []
        ) }

    it "assigns an id" do
      expect(account.id).not_to be_nil
    end

    it "sets customer_id" do
      expect(account.customer_id).to eq("ref-id-123")
    end

    it "sets balance" do
      expect(account.balance).to eq(1.0)
    end

    it "sets account_type" do
      expect(account.account_type).to eq("example")
    end

    it "sets daily_limit" do
      expect(account.daily_limit).to eq(1.0)
    end

    it "sets status" do
      expect(account.status).to eq("example")
    end

    it "sets ledger" do
      expect(account.ledger).to eq([])
    end
  end

  describe "account_type validation" do
    it "rejects nil account_type" do
      expect {
        described_class.new(
          customer_id: "ref-id-123",
          balance: 1.0,
          account_type: nil,
          daily_limit: 1.0,
          status: "example",
          ledger: []
        )
      }.to raise_error(BankingDomain::ValidationError, /account_type/)
    end
  end

  describe "identity" do
    it "two Accounts with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          customer_id: "ref-id-123",
          balance: 1.0,
          account_type: "example",
          daily_limit: 1.0,
          status: "example",
          ledger: [],
          id: id
        )
      b = described_class.new(
          customer_id: "ref-id-123",
          balance: 1.0,
          account_type: "example",
          daily_limit: 1.0,
          status: "example",
          ledger: [],
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Accounts with different ids are not equal" do
      a = described_class.new(
          customer_id: "ref-id-123",
          balance: 1.0,
          account_type: "example",
          daily_limit: 1.0,
          status: "example",
          ledger: []
        )
      b = described_class.new(
          customer_id: "ref-id-123",
          balance: 1.0,
          account_type: "example",
          daily_limit: 1.0,
          status: "example",
          ledger: []
        )
      expect(a).not_to eq(b)
    end
  end
end
