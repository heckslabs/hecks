require_relative "../../spec_helper"

RSpec.describe BankingDomain::Customer::Events::SuspendedCustomer do
  subject(:event) { described_class.new(customer_id: "example") }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries customer_id" do
    expect(event.customer_id).to eq("example")
  end
end
