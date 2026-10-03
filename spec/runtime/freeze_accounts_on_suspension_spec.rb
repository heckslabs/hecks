require "spec_helper"

# The for_each fan-out of FreezeAccountsOnSuspension: each open account of the suspended
# customer is frozen. Payload forwarding needs a projection, see the example below.
RSpec.describe "FreezeAccountsOnSuspension" do
  def build
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks.hecksagon("Banking") do
        attaches "Governance"
        Banking::Customer.persisted_by("Memory")
        Banking::Account.persisted_by("Memory")
        Banking::ATMCard.persisted_by("Memory")
        Banking::Transfer.persisted_by("Memory")
        Banking::CardPayment.persisted_by("Memory")
        Banking::ExternalTransfer.persisted_by("Memory")
        Banking::ScheduledPayment.persisted_by("Memory")
        Banking::SafeDepositBox.persisted_by("Memory")
        Banking::OnboardingCase.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  it "freezes every open account the suspended customer holds, and only theirs" do
    runtime = build
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                        name:      { given: "Ada", family: "Lovelace" },
                                                        email:     { address: "ada@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    runtime.dispatch_flat("Banking::Account.Open", customer: "CUST-0001", number: { value: "acct-2" },
                                               kind: { name: "savings" }, daily_limit: { cents: 10_000 })

    runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "CUST-0001" },
                                                       standing:  { value: "chargeback investigation" })

    fan = runtime.reactions.select { |r| r[:policy] == "FreezeAccountsOnSuspension" }
    expect(fan.map { |r| r[:for_row] }).to contain_exactly("acct-1", "acct-2")
    expect(fan).to all(include(delivered: true))

    repository = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account"))
    expect(repository.find("acct-1").state[:status]).to eq("frozen")
    expect(repository.find("acct-2").state[:status]).to eq("frozen")
  end

  # Without `with: { account: :account }` the whole `CustomerSuspended` payload rides
  # along and FreezeAccount, which declares no arguments, refuses with `does not declare
  # standing`.
  it "hands the trigger the row and nothing else, so the event's own fields never reach it" do
    runtime = build
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                        name:      { given: "Ada", family: "Lovelace" },
                                                        email:     { address: "ada@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "CUST-0001" },
                                                       standing:  { value: "chargeback investigation" })

    fan = runtime.reactions.select { |r| r[:policy] == "FreezeAccountsOnSuspension" }
    expect(fan.filter_map { |r| r[:reason] }).to be_empty
  end

  it "Account.OpenForCustomer answers correctly on its own — the for_each target, scoped to ONE customer, " \
     "ready for whichever gap closes first" do
    runtime = build
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                        name:      { given: "Ada", family: "Lovelace" },
                                                        email:     { address: "ada@example.com" })
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "CUST-0002" },
                                                        name:      { given: "Grace", family: "Hopper" },
                                                        email:     { address: "grace@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch_flat("Banking::Account.Open", customer: "CUST-0002", number: { value: "acct-2" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    rows = runtime.query("Banking::Account.OpenForCustomer", reference: { value: "CUST-0001" })

    # not acct-2 — scoped to the right customer, not every open account
    expect(rows.map { |row| row[:id] }).to eq(["acct-1"])
  end

  # The given cannot be dispatched in isolation: an open account of a suspended customer
  # is unreachable. The rule is checked as declared; the fan-out above exercises it.
  it "guards on the relationship being open, not on the customer being active" do
    runtime = build
    freeze = runtime.registry.bluebook("Banking").aggregate("Account").command("FreezeAccount")

    # "account is open" is a lifecycle guard (`from: "open"`); givens carry only
    # rules no lifecycle field can check.
    expect(freeze.givens.map(&:description)).to eq(["customer is not closed"])
    expect(freeze.from).to eq("open")
  end
end
