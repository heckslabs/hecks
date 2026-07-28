
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
    runtime.dispatch("Banking::Account.Open", id: "a1", customer: "c", number: "ACC-1",
                                              kind: "current", daily_limit: 50_000)
    runtime.dispatch("Banking::Account.Credit", id: "a1", amount: 10_000, narrative: "Opening")
    runtime.dispatch("Banking::Account.Debit",  id: "a1", amount: 2_500,  narrative: "Groceries")
  end

  it "is born with its declared identity and its lifecycle's default" do
    runtime = boot_banking
    funded_account(runtime)

    ledger = Banking::Account.find("a1").ledger
    expect(ledger.map { |e| e[:sequence] }).to eq([1, 2])
    expect(ledger.map { |e| e[:state] }).to eq(%w[posted posted])
  end

  it "is addressed through the parent, and only that element changes" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                     id: "a1", sequence: 2, narrative: "Posted in error")

    ledger = Banking::Account.find("a1").ledger
    expect(ledger[1][:state]).to     eq("reversed")
    expect(ledger[1][:narrative]).to eq("Posted in error")
    expect(ledger[0][:state]).to     eq("posted")
    expect(ledger[0][:narrative]).to eq("Opening")
  end

  it "has its own state machine, refusing in so many words" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                     id: "a1", sequence: 2, narrative: "Once")

    expect do
      runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                       id: "a1", sequence: 2, narrative: "Twice")
    end.to raise_error(Hecksagain::Runtime::LifecycleRefused,
                       'Reverse refused — state is "reversed", and Reverse moves it only from "posted"')
  end

  it "refuses an element nobody posted, naming the parent" do
    runtime = boot_banking
    funded_account(runtime)

    expect do
      runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                       id: "a1", sequence: 99, narrative: "Ghost")
    end.to raise_error(Hecksagain::Runtime::NotFound,
                       'no LedgerEntry with sequence 99 on Account "a1"')
  end

  it "answers its query with the element AND whose boundary it is" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                     id: "a1", sequence: 2, narrative: "Posted in error")

    rows = runtime.query("Banking::Account.LedgerEntry.Reversed")
    expect(rows).to eq([
      { account: "a1", sequence: 2, amount: 2_500, narrative: "Posted in error",
        direction: "debit", state: "reversed" }
    ])
  end
end
