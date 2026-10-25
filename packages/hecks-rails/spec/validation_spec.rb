require "spec_helper"

# A record asks the domain whether a command would be accepted, and keeps the answer the way Rails
# keeps validation errors: in `errors`, and against the form field it is about.
RSpec.describe Hecks::Rails::Validating do
  def grant(actor, role)
    Hecks::Rails::Booted.dispatcher.dispatch_flat(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role }, scope: { value: "Main" }, starts_at: { value: "2026-01-01" }
    )
  rescue Hecks::Refused
    nil
  end

  def as_actor(actor, &) = Hecks.as_caller(role: "", actor_id: actor, &)

  def opened(number, cents)
    Hecks.as_caller(role: "Teller") do
      Account.open_account!(number: { value: number }, owner: { name: "Ada" }, balance: { cents: cents })
    end
  end

  let(:ada) { { "number.value" => "V1", "owner.name" => "Ada", "balance.cents" => "5" } }

  before { grant("teller-v", "Teller") && grant("officer-v", "Compliance officer") }

  it "accepts a command that would pass" do
    expect(as_actor("teller-v") { Account.unsaved.valid_for?(:open_account, ada) }).to be(true)
  end

  it "keeps every reason in errors, against the attribute it is about", :aggregate_failures do
    record = Account.unsaved
    as_actor("teller-v") { record.valid_for?(:open_account, ada.except("number.value", "owner.name")) }

    expect(record.errors.attribute_names).to contain_exactly(:number, :owner)
  end

  it "finds the message for the form field a refusal was about, inside a value object", :aggregate_failures do
    record = Account.unsaved
    as_actor("teller-v") { record.valid_for?(:open_account, ada.except("number.value")) }

    expect(record.field_errors["number.value"]).to include("AccountNumber")
    expect(record.field_errors["owner.name"]).to be_nil
  end

  it "names the rule that refused a record's command", :aggregate_failures do
    record = opened("V2", 5)

    expect(as_actor("officer-v") { record.valid_for?(:freeze_account) }).to be(false)
    expect(record.errors[:base]).to include(a_string_matching(/the balance is zero/))
  end

  it "tells a caller without the role only that", :aggregate_failures do
    record = opened("V3", 0)
    refusals = as_actor("teller-v") { record.validate_command(:freeze_account) }

    expect(refusals.map(&:kind)).to eq([:unauthorized])
    expect(refusals.map(&:stage)).to eq([:role])
  end

  it "counts text in a number field as a refusal, not a crash" do
    record = Account.unsaved
    as_actor("teller-v") { record.valid_for?(:open_account, ada.merge("balance.cents" => "lots")) }

    expect(record.errors).not_to be_empty
  end

  it "saves nothing" do
    as_actor("teller-v") { Account.unsaved.valid_for?(:open_account, ada) }

    expect(Account.all.map(&:id)).not_to include("V1")
  end
end
