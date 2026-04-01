require_relative "../../spec_helper"

RSpec.describe BankingDomain::Account::Events::Deposited do
  subject(:event) { described_class.new(account_id: "example", amount: 1.0) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries account_id" do
    expect(event.account_id).to eq("example")
  end

  it "carries amount" do
    expect(event.amount).to eq(1.0)
  end
end
