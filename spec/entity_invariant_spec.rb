require "spec_helper"

# `EntityBuilder#invariant`: a piece's shape rule, checked against every instance
# at the same checkpoints as the aggregate's own invariants.
RSpec.describe "a piece's own invariant, checked against every instance the aggregate holds" do
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

  def rent_box(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "One" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::SafeDepositBox.Rent", customer: "c1",
                     branch_code: { value: "DOWNTOWN" }, box_number: { value: 1 },
                     size: { value: "small" })
  end

  def rented_runtime = boot.tap { |runtime| rent_box(runtime) }

  def log_visit(runtime, **note)
    runtime.dispatch_flat("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 1 },
                                                               date: { value: "2026-08-16" }, sequence: { value: 1 }, **note)
  end

  it "refuses a visit whose own note is present but empty" do
    expect { log_visit(rented_runtime, note: { text: "" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /Visit refused.*a written note is not blank/)
  end

  it "accepts a visit with no note at all — optional stays optional" do
    expect { log_visit(rented_runtime) }.not_to raise_error
  end

  it "accepts a visit with a genuine note" do
    expect { log_visit(rented_runtime, note: { text: "Vault officer inspected the lock." }) }.not_to raise_error
  end
end
