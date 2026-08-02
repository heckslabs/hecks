require "spec_helper"

# Every where-clause comparator the language declares (Vocabulary::QueryComparator)
# and the DSL admits (QuerySpecification::Common::COMPARATORS), exercised at
# least once — now against the real banking bluebook rather than a synthetic
# fixture invented to hold this alone. gt/gte/lt/lte/ne/in/contains were
# silently treated as `eq` in both Runtime::QueryInterpreter#holds? and
# Ports::Query::InMemory#holds? until a fixture caught it; banking's own
# Account.{Overdrawn,HighBalance,StrictlyAbove,AtMost}, Customer.NotGoodStanding,
# Account.Reachable and CardPayment.Flagged now carry that coverage instead.
RSpec.describe "where-clause comparators, exercised on the real banking bluebook" do
  BANKING_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")

  def boot
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(BANKING_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  def seed(runtime)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "One" }, email: { address: "a@example.com" })

    # a(300), b(500), c(1000, later frozen), d(0, later closed) — the four
    # corners a floor/cap comparator family needs: strictly below, exactly at,
    # strictly above, and the zero balance closure requires.
    [["a", 300], ["b", 500], ["c", 1000], ["d", 0]].each do |number, cents|
      runtime.dispatch("Banking::Account.Open", customer_id: "c1", number: { value: number },
                                                 kind: { name: "current" }, daily_limit: { cents: 100_000 })
      next unless cents.positive?

      runtime.dispatch("Banking::Account.Credit", number: { value: number }, amount: { cents: cents, currency: "USD" },
                                                   narrative: { text: "Opening" })
    end
    runtime.dispatch("Banking::Account.Freeze", number: { value: "c" })
    runtime.dispatch("Banking::Account.CloseAccount", number: { value: "d" })

    runtime.dispatch("Banking::Customer.Suspend", reference: { value: "c1" }, standing: { value: "chargeback investigation" })

    runtime.dispatch("Banking::CardPayment.Authorize", account_id: "a", authorisation: { value: "auth-1" },
                                                        amount: { cents: 4200 }, merchant: { value: "Risky Co" },
                                                        tags: [{ value: "high_risk" }])
    runtime.dispatch("Banking::CardPayment.Authorize", account_id: "b", authorisation: { value: "auth-2" },
                                                        amount: { cents: 1500 }, merchant: { value: "Ordinary Co" })
    runtime
  end

  let(:runtime) { seed(boot) }

  it "Eq matches the accounts still open" do
    numbers = runtime.query("Banking::Account.Open").map { |row| row[:number].value }
    expect(numbers).to match_array(%w[a b])
  end

  it "Ne matches customers not in good standing" do
    refs = runtime.query("Banking::Customer.NotGoodStanding").map { |row| row[:reference].value }
    expect(refs).to eq(%w[c1])
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
