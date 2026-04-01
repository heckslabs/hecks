require_relative "../spec_helper"

RSpec.describe BankingDomain::Loan::PaymentScheduleEntry do
  subject(:payment_schedule_entry) { described_class.new(
          due_date: "example",
          principal_amount: 1.0,
          interest_amount: 1.0,
          total_amount: 1.0
        ) }

  it "is immutable" do
    expect(payment_schedule_entry).to be_frozen
  end

  it "is equal when all attributes match" do
    other = described_class.new(
          due_date: "example",
          principal_amount: 1.0,
          interest_amount: 1.0,
          total_amount: 1.0
        )
    expect(payment_schedule_entry).to eq(other)
  end
end
