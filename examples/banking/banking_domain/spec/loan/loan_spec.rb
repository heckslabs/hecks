require_relative "../spec_helper"

RSpec.describe BankingDomain::Loan do
  describe "creating a Loan" do
    subject(:loan) { described_class.new(
          customer_id: "ref-id-123",
          account_id: "ref-id-123",
          principal: 1.0,
          rate: 1.0,
          term_months: 1,
          remaining_balance: 1.0,
          status: "example"
        ) }

    it "assigns an id" do
      expect(loan.id).not_to be_nil
    end

    it "sets customer_id" do
      expect(loan.customer_id).to eq("ref-id-123")
    end

    it "sets account_id" do
      expect(loan.account_id).to eq("ref-id-123")
    end

    it "sets principal" do
      expect(loan.principal).to eq(1.0)
    end

    it "sets rate" do
      expect(loan.rate).to eq(1.0)
    end

    it "sets term_months" do
      expect(loan.term_months).to eq(1)
    end

    it "sets remaining_balance" do
      expect(loan.remaining_balance).to eq(1.0)
    end

    it "sets status" do
      expect(loan.status).to eq("example")
    end
  end

  describe "principal validation" do
    it "rejects nil principal" do
      expect {
        described_class.new(
          customer_id: "ref-id-123",
          account_id: "ref-id-123",
          principal: nil,
          rate: 1.0,
          term_months: 1,
          remaining_balance: 1.0,
          status: "example"
        )
      }.to raise_error(BankingDomain::ValidationError, /principal/)
    end
  end

  describe "rate validation" do
    it "rejects nil rate" do
      expect {
        described_class.new(
          customer_id: "ref-id-123",
          account_id: "ref-id-123",
          principal: 1.0,
          rate: nil,
          term_months: 1,
          remaining_balance: 1.0,
          status: "example"
        )
      }.to raise_error(BankingDomain::ValidationError, /rate/)
    end
  end

  describe "identity" do
    it "two Loans with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          customer_id: "ref-id-123",
          account_id: "ref-id-123",
          principal: 1.0,
          rate: 1.0,
          term_months: 1,
          remaining_balance: 1.0,
          status: "example",
          id: id
        )
      b = described_class.new(
          customer_id: "ref-id-123",
          account_id: "ref-id-123",
          principal: 1.0,
          rate: 1.0,
          term_months: 1,
          remaining_balance: 1.0,
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Loans with different ids are not equal" do
      a = described_class.new(
          customer_id: "ref-id-123",
          account_id: "ref-id-123",
          principal: 1.0,
          rate: 1.0,
          term_months: 1,
          remaining_balance: 1.0,
          status: "example"
        )
      b = described_class.new(
          customer_id: "ref-id-123",
          account_id: "ref-id-123",
          principal: 1.0,
          rate: 1.0,
          term_months: 1,
          remaining_balance: 1.0,
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
