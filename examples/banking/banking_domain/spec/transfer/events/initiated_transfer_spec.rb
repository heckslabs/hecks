require_relative "../../spec_helper"

RSpec.describe BankingDomain::Transfer::Events::InitiatedTransfer do
  subject(:event) { described_class.new(
          from_account_id: "example",
          to_account_id: "example",
          amount: 1.0,
          memo: "example"
        ) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries from_account_id" do
    expect(event.from_account_id).to eq("example")
  end

  it "carries to_account_id" do
    expect(event.to_account_id).to eq("example")
  end

  it "carries amount" do
    expect(event.amount).to eq(1.0)
  end

  it "carries memo" do
    expect(event.memo).to eq("example")
  end
end
