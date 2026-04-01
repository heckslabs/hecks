require_relative "../spec_helper"

RSpec.describe BankingDomain::Loan::Disbursement do
  subject(:disbursement) { described_class.new(
          amount: 1.0,
          disbursed_at: "example",
          method: "example"
        ) }

  it "is immutable" do
    expect(disbursement).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(
          amount: 1.0,
          disbursed_at: "example",
          method: "example"
        )
    expect(disbursement).to eq(other)
  end
end
