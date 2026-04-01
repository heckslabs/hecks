require_relative "../../spec_helper"

RSpec.describe BankingDomain::Loan::Events::RefinancedLoan do
  subject(:event) { described_class.new(
          loan_id: "example",
          new_rate: 1.0,
          new_term_months: 1
        ) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries loan_id" do
    expect(event.loan_id).to eq("example")
  end

  it "carries new_rate" do
    expect(event.new_rate).to eq(1.0)
  end

  it "carries new_term_months" do
    expect(event.new_term_months).to eq(1)
  end
end
