require "spec_helper"

# Banking's account ledger, appended to without naming a sequence: each entry's identity is
# minted, so identical writes never read as a collision. The balance invariant over generated
# traces is held by the property battery (spec/fuzzing/properties_spec.rb) and the refusal
# fixture (spec/categories/refusal_kinds_spec.rb).
RSpec.describe "Banking's generated account machine" do
  STATE_MACHINE_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR

  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      MemoryPorts.load!
      load_bluebook_files(STATE_MACHINE_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot_banking }

  def open_account(customer, number)
    person = { name: { given: "A", family: "Customer" }, email: { address: "a@example.com" } }
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: customer }, **person)
    account = { number: { value: number }, kind: { name: "current" }, daily_limit: { cents: 1_000 } }
    runtime.dispatch_flat("Banking::Account.Open", customer: customer, **account)
  end

  # Posts a Credit or Debit of `cents` to the account.
  def post(verb, number, cents, narrative)
    amount = { cents: cents, currency: "USD" }
    runtime.dispatch_flat("Banking::Account.#{verb}", number: { value: number }, amount: amount, narrative: { text: narrative })
  end

  def stored_account(number)
    runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account")).find(number)
  end

  # Negative control for MutationApplier#check_entity_collision: the append never names
  # `sequence`, so it auto-mints and identical Credits must both land.
  it "never flags an auto-minted entity list as colliding, even with identical repeated writes", :aggregate_failures do
    open_account("c1", "a1")
    3.times { post("Credit", "a1", 100, "same narrative every time") }

    stored = stored_account("a1")
    expect(stored[:ledger].size).to eq(3)
    expect(stored[:ledger].map { |entry| entry[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }, { value: 3 }])
  end
end
