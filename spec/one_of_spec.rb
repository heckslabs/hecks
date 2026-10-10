require "spec_helper"

RSpec.describe "one_of" do
  ONE_OF_BANKING = InMemoryDomain::BANKING_BLUEBOOK_DIR

  def load_ports
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
  end

  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_ports
      load_bluebook_files(ONE_OF_BANKING)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def register_customer(runtime, reference: "c", email: "a@example.com")
    runtime.dispatch_flat(
      "Banking::Customer.Register",
      reference: { value: reference }, name: { given: "A", family: "Customer" }, email: { address: email }
    )
  end

  # Boots banking, registers a customer, and opens an account of the given kind and daily limit.
  def open_account_as(kind, cents)
    runtime = boot_banking
    register_customer(runtime)
    runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                                   kind: { name: kind }, daily_limit: { cents: cents })
  end

  it "admits a declared member" do
    expect { open_account_as("savings", 10_000) }.not_to raise_error
  end

  it "refuses a value outside the set, naming the set" do
    expect { open_account_as("gold", 10_000) }
      .to raise_error(Hecks::Runtime::InvariantViolation, 'AccountKind admits "current", "savings", "reserve" — got "gold"')
  end

  # Uses DailyLimit because it is an Integer field: patterns apply only to String, so
  # no `pattern:` check shadows its invariant (EmailAddress and CustomerNumber have one).
  it "judges an object payload's invariants at the same entry point" do
    expect { open_account_as("current", -1) }
      .to raise_error(Hecks::Runtime::InvariantViolation,
                      'DailyLimit invariant violated — a daily limit is non-negative (given {"cents":-1})')
  end

  it "judges an object payload's patterns at the same entry point" do
    expect { register_customer(boot_banking, reference: "CUST-0009", email: "nowhere") }
      .to raise_error(Hecks::Runtime::TypeMismatch, 'EmailAddress.address must match ^[^@ ]+@[^@ ]+\.[^@ ]+$, got "nowhere"')
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
