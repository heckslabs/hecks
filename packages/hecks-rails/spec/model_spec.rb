require "spec_helper"

RSpec.describe Hecks::Rails::Model do
  def grant(actor, role)
    Hecks::Rails::Booted.dispatcher.dispatch_flat(
      "Governance::RoleAssignment.Assign",
      actor_id: { value: actor }, role_name: { value: role },
      scope: { value: "Main" }, starts_at: { value: "2026-01-01" }
    )
  rescue Hecks::Refused
    nil
  end

  def opened(number, cents)
    Hecks.as_caller(role: "Teller") do
      Account.open_account!(number: { value: number }, owner: { name: "Ada" }, balance: { cents: cents })
    end
  end

  it "names itself for Rails like any model" do
    expect(Account.model_name.route_key).to eq("accounts")
  end

  it "opens a persisted record through a creating command", :aggregate_failures do
    account = opened("M1", 3)

    expect(account).to be_persisted
    expect(account.to_param).to eq("M1")
  end

  it "reads a field through to the record in hand" do
    expect(opened("M2", 3).status).to eq("open")
  end

  it "answers a command's declaration for the bare verb" do
    expect(opened("M3", 3).freeze_account.role).to eq("Compliance officer")
  end

  it "refuses a command whose rule does not hold" do
    account = opened("M4", 3)

    expect { account.freeze_account! }.to be_refused_with("the balance is zero")
  end

  it "freezes when the rule holds" do
    account = opened("M5", 0)
    account.freeze_account!

    expect(account.status).to eq("frozen")
  end

  it "holds no rules of its own", :aggregate_failures do
    expect(Account).not_to respond_to(:validates)
    expect(Account).not_to respond_to(:has_many)
  end

  describe "reference lookups" do
    def requested(reference, source, destination)
      Hecks.as_caller(role: "Teller") do
        Transfer.request_transfer!(reference: { value: reference }, source: source, destination: destination)
      end
    end

    it "names a lookup after the alias and its target", :aggregate_failures do
      expect(Transfer.method_defined?(:source_account)).to be(true)
      expect(Transfer.method_defined?(:destination_account)).to be(true)
    end

    it "looks the referenced record up only when called" do
      from = opened("R1", 5)
      transfer = requested("T1", from.id, opened("R2", 0).id)

      expect(transfer.source_account.to_param).to eq("R1")
    end
  end

  describe "#available_commands" do
    before do
      grant("officer-2", "Compliance officer")
      grant("teller-2", "Teller")
    end

    it "lists what an actor with the grant may do now" do
      expect(opened("M6", 0).available_commands(as: "officer-2")).to eq(%w[freeze_account].map(&:to_sym))
    end

    it "lists nothing for an actor without the grant" do
      expect(opened("M7", 0).available_commands(as: "teller-2")).to be_empty
    end

    it "lists nothing while the rule would refuse" do
      expect(opened("M8", 9).available_commands(as: "officer-2")).to be_empty
    end
  end
end
