require_relative "../../spec_helper"

RSpec.describe BankingDomain::Loan::Events::DefaultedLoan do
  subject(:event) { described_class.new(loan_id: "example", customer_id: "example") }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries loan_id" do
    expect(event.loan_id).to eq("example")
  end

  it "carries customer_id" do
    expect(event.customer_id).to eq("example")
  end
end
