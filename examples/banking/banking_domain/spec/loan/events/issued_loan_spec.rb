require_relative "../../spec_helper"

RSpec.describe BankingDomain::Loan::Events::IssuedLoan do
  subject(:event) { described_class.new(
          customer_id: "example",
          account_id: "example",
          principal: 1.0,
          rate: 1.0,
          term_months: 1
        ) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries customer_id" do
    expect(event.customer_id).to eq("example")
  end

  it "carries account_id" do
    expect(event.account_id).to eq("example")
  end

  it "carries principal" do
    expect(event.principal).to eq(1.0)
  end

  it "carries rate" do
    expect(event.rate).to eq(1.0)
  end

  it "carries term_months" do
    expect(event.term_months).to eq(1)
  end
end
