require "spec_helper"

# The for_each fan-out of FreezeAccountsOnSuspension: each open account of the suspended
# customer is frozen. Payload forwarding needs a projection, see the example below.
RSpec.describe "FreezeAccountsOnSuspension" do
  FREEZE_BANKING_AGGREGATES = ["Customer", "Account", "ATMCard", "Transfer", "CardPayment", "ExternalTransfer",
                               "ScheduledPayment", "SafeDepositBox", "OnboardingCase"].freeze

  def bind_hecksagons
    Hecks.hecksagon("Banking") do
      attaches "Governance"
      FREEZE_BANKING_AGGREGATES.each { |name| Banking.const_get(name).persisted_by("Memory") }
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def load_memory_stack
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
  end

  def build
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      load_memory_stack
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      bind_hecksagons
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def register_customer(runtime, reference, given, family)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: reference },
                          name: { given: given, family: family }, email: { address: "#{given.downcase}@example.com" })
  end

  def open_account(runtime, customer, number, kind, cents)
    runtime.dispatch_flat("Banking::Account.Open", customer: customer, number: { value: number },
                          kind: { name: kind }, daily_limit: { cents: cents })
  end

  def suspend(runtime)
    runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "CUST-0001" },
                                                       standing:  { value: "chargeback investigation" })
  end

  def fan_out(runtime) = runtime.reactions.select { |r| r[:policy] == "FreezeAccountsOnSuspension" }

  def account_status(runtime, number)
    repository = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account"))
    repository.find(number).state[:status]
  end

  # Ada with one current account, as the suspension examples start.
  def runtime_with_ada
    runtime = build
    register_customer(runtime, "CUST-0001", "Ada", "Lovelace")
    open_account(runtime, "CUST-0001", "acct-1", "current", 50_000)
    runtime
  end

  def runtime_with_ada_and_savings
    runtime = runtime_with_ada
    open_account(runtime, "CUST-0001", "acct-2", "savings", 10_000)
    runtime
  end

  it "freezes every open account the suspended customer holds, and only theirs", :aggregate_failures do
    runtime = runtime_with_ada_and_savings

    suspend(runtime)

    expect(fan_out(runtime).map { |r| r[:for_row] }).to contain_exactly("acct-1", "acct-2")
    expect(fan_out(runtime)).to all(include(delivered: true))
    expect([account_status(runtime, "acct-1"), account_status(runtime, "acct-2")]).to eq(["frozen", "frozen"])
  end

  # Without `with: { account: :account }` the whole `CustomerSuspended` payload rides
  # along and FreezeAccount, which declares no arguments, refuses with `does not declare
  # standing`.
  it "hands the trigger the row and nothing else, so the event's own fields never reach it" do
    runtime = runtime_with_ada

    suspend(runtime)

    expect(fan_out(runtime).filter_map { |r| r[:reason] }).to be_empty
  end

  it "Account.OpenForCustomer answers correctly on its own — the for_each target, scoped to ONE customer, " \
     "ready for whichever gap closes first" do
    runtime = runtime_with_ada
    register_customer(runtime, "CUST-0002", "Grace", "Hopper")
    open_account(runtime, "CUST-0002", "acct-2", "current", 50_000)

    rows = runtime.query("Banking::Account.OpenForCustomer", reference: { value: "CUST-0001" })

    # not acct-2 — scoped to the right customer, not every open account
    expect(rows.map { |row| row[:id] }).to eq(["acct-1"])
  end

  # The given cannot be dispatched in isolation: an open account of a suspended customer
  # is unreachable. The rule is checked as declared; the fan-out above exercises it.
  it "guards on the relationship being open, not on the customer being active", :aggregate_failures do
    runtime = build
    freeze = runtime.registry.bluebook("Banking").aggregate("Account").command("FreezeAccount")

    # "account is open" is a lifecycle guard (`from: "open"`); givens carry only
    # rules no lifecycle field can check.
    expect(freeze.givens.map(&:description)).to eq(["customer is not closed"])
    expect(freeze.from).to eq("open")
  end
end
