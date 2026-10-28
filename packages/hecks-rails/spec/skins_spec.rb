require "spec_helper"

RSpec.describe Hecks::Rails::Skins do
  def post_note(slug, text)
    Hecks.as_caller(role: "Teller") { Note.post_note!(slug: { value: slug }, text: { value: text }) }
  end

  it "generates a model for an aggregate the app wrote none for", :aggregate_failures do
    expect(Account.superclass).to eq(ApplicationRecord)
    expect(Account.name).to eq("Account")
  end

  it "leaves a model the app wrote alone", :aggregate_failures do
    expect(Note.instance_method(:headline).owner).to eq(Note)
    expect(Note.superclass).to eq(ApplicationRecord)
  end

  it "runs the app's own model against the domain" do
    expect(post_note("n1", "hello").headline).to eq("HELLO")
  end

  it "generates the base model and none for a framework bluebook such as Governance" do
    expect(described_class.generated.keys).to contain_exactly("ApplicationRecord", "Account", "Desk", "Transfer")
  end

  it "reaches the aggregate through its bluebook, not a top-level module" do
    expect(Ledger::Account.ir.hecks_name).to eq("Account")
  end
end
