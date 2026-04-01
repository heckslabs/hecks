require_relative "../../spec_helper"

RSpec.describe BankingDomain::Transfer::Events::CompletedTransfer do
  subject(:event) { described_class.new(transfer_id: "example") }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries transfer_id" do
    expect(event.transfer_id).to eq("example")
  end
end
