require_relative "../../spec_helper"

RSpec.describe BankingDomain::Loan::Events::MadePayment do
  subject(:event) { described_class.new(loan_id: "example", amount: 1.0) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries loan_id" do
    expect(event.loan_id).to eq("example")
  end

  it "carries amount" do
    expect(event.amount).to eq(1.0)
  end
end
