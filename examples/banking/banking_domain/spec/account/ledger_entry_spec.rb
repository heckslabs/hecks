require_relative "../spec_helper"

RSpec.describe BankingDomain::Account::LedgerEntry do
  subject(:ledger_entry) { described_class.new(
          amount: 1.0,
          description: "example",
          entry_type: "example",
          posted_at: "example"
        ) }

  it "has a UUID id" do
    expect(ledger_entry.id).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "is mutable (not frozen)" do
    expect(ledger_entry).not_to be_frozen
  end

  it "uses identity-based equality" do
    id = SecureRandom.uuid
    a = described_class.new(
          amount: 1.0,
          description: "example",
          entry_type: "example",
          posted_at: "example"
        , id: id)
    b = described_class.new(
          amount: 1.0,
          description: "example",
          entry_type: "example",
          posted_at: "example"
        , id: id)
    expect(a).to eq(b)
  end
end
