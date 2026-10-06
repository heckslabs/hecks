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
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def open_account(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                          name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                          kind: { name: "current" }, daily_limit: { cents: 50_000 })
  end

  def post(runtime, verb, cents, text)
    runtime.dispatch_flat("Banking::Account.#{verb}", number: { value: "a1" },
                          amount: { cents: cents, currency: "USD" }, narrative: { text: text })
  end

  def funded_account(runtime)
    open_account(runtime)
    post(runtime, "Credit", 10_000, "Opening")
    post(runtime, "Debit", 2_500, "Groceries")
  end

  def reverse_entry(runtime, sequence, text)
    runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                          number: { value: "a1" }, sequence: { value: sequence }, narrative: { text: text })
  end

  let(:runtime) { boot_banking }

  def reversed_rows
    runtime.query("Banking::Account.LedgerEntry.Reversed").map do |row|
      row.transform_values { |value| Hecks::Runtime::Value.materialize(value) }
    end
  end

  def reversed_debit_row
    { account: "a1", sequence: { value: 2 }, amount: { cents: 2_500, currency: "USD" },
      narrative: { text: "Posted in error" }, direction: { value: "debit" }, state: "reversed" }
  end

  it "is born with its declared identity and its lifecycle's default", :aggregate_failures do
    funded_account(runtime)

    ledger = Banking::Account.find("a1").ledger
    expect(ledger.map { |e| e[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }])
    expect(ledger.map { |e| e[:state] }).to eq(%w[posted posted])
  end

  it "validates a nested value object before appending an entity" do
    open_account(runtime)

    # Coercion runs before invariants, so a blank narrative is a TypeMismatch,
    # not an InvariantViolation.
    expect { post(runtime, "Credit", 100, "") }
      .to raise_error(Hecks::Runtime::TypeMismatch, 'Narrative.text must match [^ \t\n\r], got ""')
  end

  it "is addressed through the parent, and only that element changes", :aggregate_failures do
    funded_account(runtime)
    reverse_entry(runtime, 2, "Posted in error")

    ledger = Banking::Account.find("a1").ledger
    expect([ledger[1][:state], ledger[1][:narrative].to_h]).to eq(["reversed", { text: "Posted in error" }])
    expect([ledger[0][:state], ledger[0][:narrative].to_h]).to eq(["posted", { text: "Opening" }])
  end

  it "has its own state machine, refusing in so many words" do
    funded_account(runtime)
    reverse_entry(runtime, 2, "Once")

    # `enforce_givens` runs before `admissible_transition` (DISPATCH_ORDER), so the
    # given refuses first: GivenNotMet, not LifecycleRefused.
    expect { reverse_entry(runtime, 2, "Twice") }
      .to raise_error(Hecks::Runtime::GivenNotMet, "Reverse refused — entry is posted")
  end

  it "refuses an element nobody posted, naming the parent" do
    funded_account(runtime)

    # The message names the declared path ("sequence.value"), not just the head.
    expect { reverse_entry(runtime, 99, "Ghost") }
      .to raise_error(Hecks::Runtime::NotFound, 'no LedgerEntry with sequence.value 99 on Account "a1"')
  end

  it "refuses an element by an identity that fails its own type's invariant as NotFound, not InvariantViolation" do
    # `sequence: 0` fails LedgerSequence's invariant but must still answer NotFound,
    # as Rust does: its `extract_wants` never rebuilds the typed value.
    funded_account(runtime)

    expect { reverse_entry(runtime, 0, "Ghost") }
      .to raise_error(Hecks::Runtime::NotFound, 'no LedgerEntry with sequence.value 0 on Account "a1"')
  end

  it "answers its query with the element AND whose boundary it is" do
    funded_account(runtime)
    reverse_entry(runtime, 2, "Posted in error")

    expect(reversed_rows).to eq([reversed_debit_row])
  end
end
