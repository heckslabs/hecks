require "spec_helper"

RSpec.describe "Banking's generated account machine" do
  STATE_MACHINE_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR

  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(STATE_MACHINE_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  # One shared boot: each seed uses its own customer ref and account number.
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

  # Whether the stored balance is the model's and not negative.
  def sound?(balance, model) = balance.to_h == { cents: model, currency: "USD" } && balance.cents >= 0

  def stored_account(number)
    runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account")).find(number)
  end

  # The model's balance after the step: unchanged when the runtime refuses it.
  def apply_step(seed, verb, amount, model)
    post(verb, "a#{seed}", amount, "generated #{seed}")
    model + (verb == "Credit" ? amount : -amount)
  rescue Hecks::Runtime::GivenNotMet, Hecks::Runtime::InvariantViolation
    model
  end

  # Fifty random credits and debits on a fresh account; one sentence for each step after which the
  # stored balance departs from the model's, or goes negative.
  def balance_violations(seed)
    open_account("c#{seed}", "a#{seed}")
    model = 0
    random = Random.new(seed)

    Array.new(50) do
      amount = random.rand(-200..1_200)
      verb   = random.rand(2).zero? ? "Credit" : "Debit"
      model  = apply_step(seed, verb, amount, model)
      balance = stored_account("a#{seed}")[:balance]
      "seed #{seed}: stored #{balance.to_h.inspect}, model #{model}" unless sound?(balance, model)
    end.compact
  end

  it "preserves the account balance invariant across deterministic command traces" do
    expect(20.times.flat_map { |seed| balance_violations(seed) }).to be_empty
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
