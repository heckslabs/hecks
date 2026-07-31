
require "spec_helper"

RSpec.describe "an entity" do
  BANKING_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")

  def boot_banking
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(BANKING_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def funded_account(runtime)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer_id: { value: "c" }, number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch("Banking::Account.Credit", number: { value: "a1" }, amount: { cents: 10_000, currency: "USD" }, narrative: { text: "Opening" })
    runtime.dispatch("Banking::Account.Debit", number: { value: "a1" },  amount: { cents: 2_500, currency: "USD" },  narrative: { text: "Groceries" })
  end

  it "is born with its declared identity and its lifecycle's default" do
    runtime = boot_banking
    funded_account(runtime)

    ledger = Banking::Account.find("a1").ledger
    expect(ledger.map { |e| e[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }])
    expect(ledger.map { |e| e[:state] }).to eq(%w[posted posted])
  end

  it "validates a nested value object before appending an entity" do
    runtime = boot_banking
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer_id: { value: "c" }, number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })

    expect do
      runtime.dispatch("Banking::Account.Credit", number: { value: "a1" }, amount: { cents: 100, currency: "USD" }, narrative: { text: "" })
    end.to raise_error(Hecksagain::Runtime::InvariantViolation,
                       'Narrative invariant violated — a movement explains itself (given {"text":""})')
  end

  it "is addressed through the parent, and only that element changes" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                     number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "Posted in error" })

    ledger = Banking::Account.find("a1").ledger
    expect(ledger[1][:state]).to     eq("reversed")
    expect(ledger[1][:narrative].to_h).to eq(text: "Posted in error")
    expect(ledger[0][:state]).to     eq("posted")
    expect(ledger[0][:narrative].to_h).to eq(text: "Opening")
  end

  it "has its own state machine, refusing in so many words" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                     number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "Once" })

    expect do
      runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                       number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "Twice" })
    end.to raise_error(Hecksagain::Runtime::LifecycleRefused,
                       'Reverse refused — state is "reversed", and Reverse moves it only from "posted"')
  end

  it "refuses an element nobody posted, naming the parent" do
    runtime = boot_banking
    funded_account(runtime)

    expect do
      runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                       number: { value: "a1" }, sequence: { value: 99 }, narrative: { text: "Ghost" })
    end.to raise_error(Hecksagain::Runtime::NotFound,
                       'no LedgerEntry with sequence 99 on Account "a1"')
  end

  it "answers its query with the element AND whose boundary it is" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                     number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "Posted in error" })

    rows = runtime.query("Banking::Account.LedgerEntry.Reversed")
    materialized = rows.map { |row| row.transform_values { |value| Hecksagain::Runtime::Value.materialize(value) } }
    expect(materialized).to eq([
      { account: "a1", sequence: { value: 2 }, amount: { cents: 2_500, currency: "USD" }, narrative: { text: "Posted in error" },
        direction: { value: "debit" }, state: "reversed" }
    ])
  end
end
