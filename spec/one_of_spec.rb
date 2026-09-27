require "spec_helper"

RSpec.describe "one_of" do
  ONE_OF_BANKING = InMemoryDomain::BANKING_BLUEBOOK_DIR

  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(ONE_OF_BANKING)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  it "admits a declared member" do
    runtime = boot_banking

    expect do
      runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                                kind: { name: "savings" }, daily_limit: { cents: 10_000 })
    end.not_to raise_error
  end

  it "refuses a value outside the set, naming the set" do
    runtime = boot_banking

    expect do
      runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                                kind: { name: "gold" }, daily_limit: { cents: 10_000 })
    end.to raise_error(Hecks::Runtime::InvariantViolation,
                       'AccountKind admits "current", "savings", "reserve" — got "gold"')
  end

  # Uses DailyLimit because it is an Integer field: patterns apply only to String, so
  # no `pattern:` check shadows its invariant (EmailAddress and CustomerNumber have one).
  it "judges an object payload's invariants at the same door" do
    runtime = boot_banking

    expect do
      runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                                kind: { name: "current" }, daily_limit: { cents: -1 })
    end.to raise_error(Hecks::Runtime::InvariantViolation,
                       'DailyLimit invariant violated — a daily limit is non-negative (given {"cents":-1})')
  end

  it "judges an object payload's patterns at the same door" do
    runtime = boot_banking

    expect do
      runtime.dispatch_flat("Banking::Customer.Register",
                            reference: { value: "CUST-0009" },
                            name:      { given: "No", family: "Route" },
                            email:     { address: "nowhere" })
    end.to raise_error(Hecks::Runtime::TypeMismatch,
                       'EmailAddress.address must match ^[^@ ]+@[^@ ]+\.[^@ ]+$, got "nowhere"')
  end

  # Pins that every column of a multi-column member row is checked, not only the
  # discriminant (first) column: a matching `cadence` must not admit bad other columns.
  describe "a multi-column one_of (StatementFrequency)" do
    def statement_frequency
      boot_banking.registry.bluebook("Banking").aggregate("Statement").value_object("StatementFrequency")
    end

    it "admits a row that matches every declared column" do
      vo = statement_frequency

      expect do
        Hecks::Runtime::Value.build(vo, cadence: "monthly", retention_months: 84, paper_fee_cents: 0)
      end.not_to raise_error
    end

    it "refuses a row whose discriminant matches a member but whose other columns do not" do
      vo = statement_frequency

      expect do
        Hecks::Runtime::Value.build(vo, cadence: "monthly", retention_months: 999, paper_fee_cents: 999)
      end.to raise_error(Hecks::Runtime::InvariantViolation, /StatementFrequency admits/)
    end
  end
end
