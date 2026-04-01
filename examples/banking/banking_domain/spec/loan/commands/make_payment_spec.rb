require_relative "../../spec_helper"

RSpec.describe BankingDomain::Loan::Commands::MakePayment do
  describe "attributes" do
    subject(:command) { described_class.new(loan_id: "example", amount: 1.0) }

    it "has loan_id" do
      expect(command.loan_id).to eq("example")
    end

    it "has amount" do
      expect(command.amount).to eq(1.0)
    end

  end

  describe "event" do
    it "emits MadePayment" do
      expect(described_class.event_name).to eq("MadePayment")
    end
  end
end
