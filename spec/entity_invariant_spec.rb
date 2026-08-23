require "spec_helper"

# Round 7 — `EntityBuilder#invariant`: a piece's own shape rule,
# checked against EVERY instance the aggregate holds, at the SAME two
# checkpoints (after every mutation, before save) the aggregate's own
# invariants already run at. NOT a separate enforcement boundary — see
# Admissibility#enforce_invariants' own comment on why this does not
# contradict "there is no separate entity invariant."
#
# Real corpus exercise: SafeDepositBox's own `Visit` — "a written note
# is not blank" — an optional VisitNote a vault officer wrote nothing
# but empty text into.
RSpec.describe "a piece's own invariant, checked against every instance the aggregate holds" do
  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR

  def boot
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(BANKING_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  def rent_box(runtime)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "One" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::SafeDepositBox.Rent", customer: "c1",
                     branch_code: { value: "DOWNTOWN" }, box_number: { value: 1 },
                     size: { value: "small" })
  end

  it "refuses a visit whose own note is present but empty" do
    runtime = boot
    rent_box(runtime)

    expect do
      runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 1 },
                       date: { value: "2026-08-16" }, sequence: { value: 1 }, note: { text: "" })
    end.to raise_error(Hecksagain::Runtime::InvariantViolation, /Visit refused.*a written note is not blank/)
  end

  it "accepts a visit with no note at all — optional stays optional" do
    runtime = boot
    rent_box(runtime)

    expect do
      runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 1 },
                       date: { value: "2026-08-16" }, sequence: { value: 1 })
    end.not_to raise_error
  end

  it "accepts a visit with a genuine note" do
    runtime = boot
    rent_box(runtime)

    expect do
      runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 1 },
                       date: { value: "2026-08-16" }, sequence: { value: 1 }, note: { text: "Vault officer inspected the lock." })
    end.not_to raise_error
  end
end
