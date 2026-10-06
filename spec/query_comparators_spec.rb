require "spec_helper"

# Every where-clause comparator the language declares (Vocabulary::QueryComparator) is exercised
# at least once against the real banking bluebook.
RSpec.describe "where-clause comparators, exercised on the real banking bluebook" do
  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR unless defined?(BANKING_BLUEBOOK)

  def boot
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(BANKING_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def register_customers(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "One" }, email: { address: "a@example.com" })

    # c2 holds no accounts: `FreezeAccountsOnSuspension` freezes every open account of a suspended
    # customer, so suspending c1 would empty the account-comparator tests.
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c2" },
                     name: { given: "B", family: "Two" }, email: { address: "b@example.com" })
  end

  # a(300), b(500), c(1000, later frozen), d(0, later closed): strictly below, exactly at,
  # strictly above, and the zero balance closure requires.
  def open_accounts(runtime)
    [["a", 300], ["b", 500], ["c", 1000], ["d", 0]].each do |number, cents|
      runtime.dispatch_flat("Banking::Account.Open", customer: "c1", number: { value: number },
                                                 kind: { name: "current" }, daily_limit: { cents: 100_000 })
      next unless cents.positive?

      runtime.dispatch_flat("Banking::Account.Credit", number: { value: number }, amount: { cents: cents, currency: "USD" },
                                                   narrative: { text: "Opening" })
    end
    runtime.dispatch_flat("Banking::Account.FreezeAccount", number: { value: "c" })
    runtime.dispatch_flat("Banking::Account.CloseAccount", number: { value: "d" })
  end

  def authorize_payments_and_suspend_c2(runtime)
    runtime.dispatch_flat("Banking::CardPayment.Authorize", account: "a", authorisation: { value: "auth-1" },
                                                        amount: { cents: 4200 }, merchant: { value: "Risky Co" },
                                                        tags: [{ value: "high_risk" }])
    runtime.dispatch_flat("Banking::CardPayment.Authorize", account: "b", authorisation: { value: "auth-2" },
                                                        amount: { cents: 1500 }, merchant: { value: "Ordinary Co" })

    runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "c2" },
                                                       standing:  { value: "chargeback investigation" })
  end

  def seed(runtime)
    register_customers(runtime)
    open_accounts(runtime)
    authorize_payments_and_suspend_c2(runtime)
    runtime
  end

  # Seeded once per file: every example only queries, so the runtime is safe to share.
  before(:context) { @runtime = seed(boot) }

  let(:runtime) { @runtime }

  it "Eq matches the accounts still open" do
    numbers = runtime.query("Banking::Account.Open").map { |row| row[:number].value }
    expect(numbers).to match_array(%w[a b])
  end

  it "Ne matches customers not in good standing" do
    refs = runtime.query("Banking::Customer.NotGoodStanding").map { |row| row[:reference].value }
    expect(refs).to eq(%w[c2])
  end

  it "Gt matches balances strictly above the floor" do
    numbers = runtime.query("Banking::Account.StrictlyAbove", floor: { cents: 500 }).map { |row| row[:number].value }
    expect(numbers).to eq(%w[c])
  end

  it "Gte matches balances at or above the floor" do
    numbers = runtime.query("Banking::Account.HighBalance", floor: { cents: 500 }).map { |row| row[:number].value }
    expect(numbers).to match_array(%w[b c])
  end

  it "Lt matches balances strictly below the floor" do
    numbers = runtime.query("Banking::Account.Overdrawn", floor: { cents: 500 }).map { |row| row[:number].value }
    expect(numbers).to match_array(%w[a d])
  end

  it "Lte matches balances at or below the cap" do
    numbers = runtime.query("Banking::Account.AtMost", cap: { cents: 500 }).map { |row| row[:number].value }
    expect(numbers).to match_array(%w[a b d])
  end

  it "In matches accounts short of closed" do
    numbers = runtime.query("Banking::Account.Reachable").map { |row| row[:number].value }
    expect(numbers).to match_array(%w[a b c])
  end

  it "Contains matches payments carrying the tag" do
    ids = runtime.query("Banking::CardPayment.Flagged").map { |row| row[:id] }
    expect(ids).to eq(%w[auth-1])
  end
end
