require "spec_helper"

RSpec.describe "an entity" do
  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR unless defined?(BANKING_BLUEBOOK)

  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(BANKING_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def funded_account(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch_flat("Banking::Account.Credit", number: { value: "a1" }, amount: { cents: 10_000, currency: "USD" },
narrative: { text: "Opening" })
    runtime.dispatch_flat("Banking::Account.Debit", number: { value: "a1" }, amount: { cents: 2_500, currency: "USD" },
narrative: { text: "Groceries" })
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
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })

    # Coercion runs before invariants, so a blank narrative is a TypeMismatch,
    # not an InvariantViolation.
    expect do
      runtime.dispatch_flat("Banking::Account.Credit", number: { value: "a1" }, amount: { cents: 100, currency: "USD" },
narrative: { text: "" })
    end.to raise_error(Hecks::Runtime::TypeMismatch,
                       'Narrative.text must match [^ \t\n\r], got ""')
  end

  it "is addressed through the parent, and only that element changes" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                          number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "Posted in error" })

    ledger = Banking::Account.find("a1").ledger
    expect(ledger[1][:state]).to eq("reversed")
    expect(ledger[1][:narrative].to_h).to eq(text: "Posted in error")
    expect(ledger[0][:state]).to eq("posted")
    expect(ledger[0][:narrative].to_h).to eq(text: "Opening")
  end

  it "has its own state machine, refusing in so many words" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                          number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "Once" })

    # `enforce_givens` runs before `admissible_transition` (DISPATCH_ORDER), so the
    # given refuses first: GivenNotMet, not LifecycleRefused.
    expect do
      runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                            number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "Twice" })
    end.to raise_error(Hecks::Runtime::GivenNotMet, "Reverse refused — entry is posted")
  end

  it "refuses an element nobody posted, naming the parent" do
    runtime = boot_banking
    funded_account(runtime)

    expect do
      runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                            number: { value: "a1" }, sequence: { value: 99 }, narrative: { text: "Ghost" })
      # The message names the declared path ("sequence.value"), not just the head.
    end.to raise_error(Hecks::Runtime::NotFound,
                       'no LedgerEntry with sequence.value 99 on Account "a1"')
  end

  it "refuses an element by an identity that fails its own type's invariant as NotFound, not InvariantViolation" do
    # `sequence: 0` fails LedgerSequence's invariant but must still answer NotFound,
    # as Rust does: its `extract_wants` never rebuilds the typed value.
    runtime = boot_banking
    funded_account(runtime)

    expect do
      runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                            number: { value: "a1" }, sequence: { value: 0 }, narrative: { text: "Ghost" })
    end.to raise_error(Hecks::Runtime::NotFound,
                       'no LedgerEntry with sequence.value 0 on Account "a1"')
  end

  it "answers its query with the element AND whose boundary it is" do
    runtime = boot_banking
    funded_account(runtime)
    runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                          number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "Posted in error" })

    rows = runtime.query("Banking::Account.LedgerEntry.Reversed")
    materialized = rows.map { |row| row.transform_values { |value| Hecks::Runtime::Value.materialize(value) } }
    expect(materialized).to eq([
                                 { account: "a1", sequence: { value: 2 }, amount: { cents: 2_500, currency: "USD" },
                                   narrative: { text: "Posted in error" },
                                   direction: { value: "debit" }, state: "reversed" }
                               ])
  end
end
