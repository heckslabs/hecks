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
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                                kind: { name: "savings" }, daily_limit: { cents: 10_000 })
    end.not_to raise_error
  end

  it "refuses a value outside the set, naming the set" do
    runtime = boot_banking

    expect do
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                                kind: { name: "gold" }, daily_limit: { cents: 10_000 })
    end.to raise_error(Hecks::Runtime::InvariantViolation,
                       'AccountKind admits "current", "savings", "reserve" — got "gold"')
  end

  # This used to reach the door through EmailAddress, whose rule was the
  # hand-rolled invariant `address.include?("@")`. That rule is a declared
  # `pattern:` now, so the example moved to CustomerNumber, a value object
  # that still HAD an invariant with nothing else guarding it — otherwise
  # the test would have kept its name and quietly stopped testing
  # invariants at all.
  #
  # CustomerNumber has since gained a `pattern:` of its own (the
  # whitespace-only sweep — banking's own value objects, alongside
  # shape.bluebook's), so a blank reference is refused as a TypeMismatch
  # now, before CustomerNumber's invariant is ever reached — the identical
  # shift EmailAddress went through. DailyLimit is an Integer field with
  # no pattern to shadow it (patterns only ever apply to String), so its
  # own invariant is genuinely still what fires here.
  it "judges an object payload's invariants at the same door" do
    runtime = boot_banking

    expect do
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                                kind: { name: "current" }, daily_limit: { cents: -1 })
    end.to raise_error(Hecks::Runtime::InvariantViolation,
                       'DailyLimit invariant violated — a daily limit is non-negative (given {"cents":-1})')
  end

  it "judges an object payload's patterns at the same door" do
    runtime = boot_banking

    expect do
      runtime.dispatch("Banking::Customer.Register",
                       reference: { value: "CUST-0009" },
                       name:      { given: "No", family: "Route" },
                       email:     { address: "nowhere" })
    end.to raise_error(Hecks::Runtime::TypeMismatch,
                       'EmailAddress.address must match ^[^@ ]+@[^@ ]+\.[^@ ]+$, got "nowhere"')
  end
end
