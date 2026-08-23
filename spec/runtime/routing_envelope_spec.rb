require "spec_helper"

RSpec.describe "receiver routing outside the command payload" do
  def boot_banking
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  def logged_visit(runtime)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::SafeDepositBox.Rent", customer: "c", branch_code: { value: "DOWNTOWN" },
                                                     box_number: { value: 12 }, size: { value: "medium" })
    runtime.dispatch("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" },
                                                         box_number: { value: 12 },
                                                         date: { value: "2026-01-05" }, sequence: { value: 1 })
  end

  it "routes aggregate and entity identities separately from Annotate's facts" do
    runtime = boot_banking
    logged_visit(runtime)

    result = runtime.dispatch(
      "Banking::SafeDepositBox.Visit.Annotate",
      to:   { aggregate: "DOWNTOWN:12", entity: "2026-01-05:1" },
      with: { note: { text: "Flagged" } }
    )

    visit = Banking::SafeDepositBox.find("DOWNTOWN:12").visits.first
    expect(visit[:note].to_h).to eq(text: "Flagged")
    expect(result.execution_plan).not_to be_state_independent
    expect(result.execution_plan.strategy_for).to eq(:load_apply_validate_store)
    expect(result.persistence_outcome.status).to eq(:saved)
  end

  it "refuses receiver identity smuggled back into an explicit payload" do
    runtime = boot_banking
    logged_visit(runtime)

    expect do
      runtime.dispatch(
        "Banking::SafeDepositBox.Visit.Annotate",
        to:   { aggregate: "DOWNTOWN:12", entity: "2026-01-05:1" },
        with: { date: { value: "2026-01-05" }, note: { text: "Flagged" } }
      )
    end.to raise_error(Hecksagain::Runtime::UnknownArgument, /Annotate does not declare date.*it takes note/)
  end

  it "refuses an incomplete entity routing envelope before touching state" do
    runtime = boot_banking
    logged_visit(runtime)

    expect do
      runtime.dispatch(
        "Banking::SafeDepositBox.Visit.Annotate",
        to:   "DOWNTOWN:12",
        with: { note: { text: "Flagged" } }
      )
    end.to raise_error(Hecksagain::Runtime::TypeMismatch, /needs 1 entity identity.*got 0/)
  end
end
