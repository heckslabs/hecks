require_relative "spec_helper"

# A thin model over Banking's Account (ADR 0121): the bare verb answers its IR command, the bang
# form dispatches and pours a refusal into `errors`, a reference is looked up only when asked, and
# `available_commands` asks the domain what an actor could do now.
RSpec.describe Hecks::Rails::Model do
  let(:officer) { fresh("officer-") }
  let(:customer) { fresh("c") }
  let(:number) { fresh("a") }

  before do
    grant(officer, "Compliance officer")
    register_customer(customer)
  end

  def account
    @account ||= Account.open!(customer: customer, number: { value: number }, kind: { name: "current" },
                               daily_limit: { cents: 1000 })
  end

  it "answers a creating verb's IR command under its bare name" do
    expect(Account.open.hecks_name).to eq("Open")
  end

  it "answers a record's verb as its IR command under its bare name" do
    expect(account.freeze_account.hecks_name).to eq("FreezeAccount")
  end

  it "dispatches under the bang name" do
    expect(account.freeze_account!.status).to eq("frozen")
  end

  it "raises a refusal and keeps its words in errors", :aggregate_failures do
    account.freeze_account!
    expect { account.freeze_account! }.to be_refused_with("moves it only from \"open\"")
    expect(account.errors[:base].first).to include("FreezeAccount refused")
  end

  it "reads a reference as its identity and looks the record up only when asked", :aggregate_failures do
    expect(account.customer).to eq(customer)
    expect(account.customer_record).to eq(Customer.find(customer))
  end

  it "names a lookup for an aliased reference after the alias and its target", :aggregate_failures do
    expect(Transfer.method_defined?(:source_account)).to be(true)
    expect(Transfer.method_defined?(:destination_account)).to be(true)
  end

  it "lists the verbs an actor holding a grant could run" do
    expect(account.available_commands(as: officer).map(&:hecks_name)).to include("FreezeAccount")
  end

  it "lists none for an anonymous actor" do
    expect(account.available_commands(as: nil)).to be_empty
  end

  it "is named and routed as Rails expects", :aggregate_failures do
    expect(account.model_name.route_key).to eq("accounts")
    expect(account.to_param).to eq(number)
  end

  it "raises RecordNotFound for an identity nothing holds" do
    expect { Account.find("nowhere") }.to raise_error(Hecks::Rails::RecordNotFound)
  end
end
