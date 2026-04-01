require_relative "../../spec_helper"

RSpec.describe BankingDomain::Loan::Commands::IssueLoan do
  describe "attributes" do
    subject(:command) { described_class.new(
          customer_id: "example",
          account_id: "example",
          principal: 1.0,
          rate: 1.0,
          term_months: 1
        ) }

    it "has customer_id" do
      expect(command.customer_id).to eq("example")
    end

    it "has account_id" do
      expect(command.account_id).to eq("example")
    end

    it "has principal" do
      expect(command.principal).to eq(1.0)
    end

    it "has rate" do
      expect(command.rate).to eq(1.0)
    end

    it "has term_months" do
      expect(command.term_months).to eq(1)
    end

  end

  describe "event" do
    it "emits IssuedLoan" do
      expect(described_class.event_name).to eq("IssuedLoan")
    end
  end
end
