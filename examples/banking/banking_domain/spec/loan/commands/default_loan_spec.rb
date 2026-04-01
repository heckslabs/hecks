require_relative "../../spec_helper"

RSpec.describe BankingDomain::Loan::Commands::DefaultLoan do
  describe "attributes" do
    subject(:command) { described_class.new(loan_id: "example", customer_id: "example") }

    it "has loan_id" do
      expect(command.loan_id).to eq("example")
    end

    it "has customer_id" do
      expect(command.customer_id).to eq("example")
    end

  end

  describe "event" do
    it "emits DefaultedLoan" do
      expect(described_class.event_name).to eq("DefaultedLoan")
    end
  end
end
