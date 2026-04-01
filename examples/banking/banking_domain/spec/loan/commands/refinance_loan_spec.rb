require_relative "../../spec_helper"

RSpec.describe BankingDomain::Loan::Commands::RefinanceLoan do
  describe "attributes" do
    subject(:command) { described_class.new(
          loan_id: "example",
          new_rate: 1.0,
          new_term_months: 1
        ) }

    it "has loan_id" do
      expect(command.loan_id).to eq("example")
    end

    it "has new_rate" do
      expect(command.new_rate).to eq(1.0)
    end

    it "has new_term_months" do
      expect(command.new_term_months).to eq(1)
    end

  end

  describe "event" do
    it "emits RefinancedLoan" do
      expect(described_class.event_name).to eq("RefinancedLoan")
    end
  end
end
