require_relative "../../spec_helper"

RSpec.describe BankingDomain::Customer::Events::RegisteredCustomer do
  subject(:event) { described_class.new(name: "example", email: "example") }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries name" do
    expect(event.name).to eq("example")
  end

  it "carries email" do
    expect(event.email).to eq("example")
  end
end
