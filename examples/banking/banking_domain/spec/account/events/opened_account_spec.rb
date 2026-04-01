require_relative "../../spec_helper"

RSpec.describe BankingDomain::Account::Events::OpenedAccount do
  subject(:event) { described_class.new(
          customer_id: "example",
          account_type: "example",
          daily_limit: 1.0
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

  it "carries account_type" do
    expect(event.account_type).to eq("example")
  end

  it "carries daily_limit" do
    expect(event.daily_limit).to eq(1.0)
  end
end
