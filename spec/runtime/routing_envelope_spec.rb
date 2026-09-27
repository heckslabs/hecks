require "spec_helper"

RSpec.describe "receiver routing outside the command payload" do
  def boot_banking
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def logged_visit(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::SafeDepositBox.Rent", customer: "c", branch_code: { value: "DOWNTOWN" },
                                                     box_number: { value: 12 }, size: { value: "medium" })
    runtime.dispatch_flat("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" },
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
    end.to raise_error(Hecks::Runtime::UnknownArgument, /Annotate does not declare date.*it takes note/)
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
    end.to raise_error(Hecks::Runtime::TypeMismatch, /needs 1 entity identity.*got 0/)
  end

  # An aggregate-only envelope (`entities: []` or absent) on an entity_depth 0 command passes
  # the `entities.size != entity_depth` check trivially; Rust refuses it outright, so must Ruby.
  def open_account(runtime, ref: "c1", number: "a1")
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: ref },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: ref, number: { value: number },
                                              kind: { name: "current" }, daily_limit: { cents: 1_000 })
  end

  it "refuses entities: [] on an aggregate-level command's to:, not lets it reach the command's own validation" do
    runtime = boot_banking
    open_account(runtime)

    expect do
      runtime.dispatch(
        "Banking::Account.Credit",
        to:   { aggregate: "a1", entities: [] },
        with: { amount: { cents: 100, currency: "USD" }, narrative: { text: "x" } }
      )
    end.to raise_error(Hecks::Runtime::TypeMismatch, /entity route requires at least one entity identity/)
  end

  it "refuses an entity/entities-less aggregate Hash the same way" do
    runtime = boot_banking
    open_account(runtime)

    expect do
      runtime.dispatch(
        "Banking::Account.Credit",
        to:   { aggregate: "a1" },
        with: { amount: { cents: 100, currency: "USD" }, narrative: { text: "x" } }
      )
    end.to raise_error(Hecks::Runtime::TypeMismatch, /entity route requires at least one entity identity/)
  end

  it "still accepts the bare aggregate identity string for the same command" do
    runtime = boot_banking
    open_account(runtime)

    expect do
      runtime.dispatch(
        "Banking::Account.Credit",
        to:   "a1",
        with: { amount: { cents: 100, currency: "USD" }, narrative: { text: "x" } }
      )
    end.not_to raise_error
  end

  # Rust once judged `with:`'s value as the facts and refused UnknownArgument; both must now
  # refuse TypeMismatch (pinned Rust-side in rust/src/kernel/routing.rs).
  it "refuses with: carrying a routing-shaped object beside a loose legacy fact" do
    runtime = boot_banking
    open_account(runtime)

    expect do
      runtime.dispatch_flat(
        "Banking::Account.Credit",
        amount: { cents: 100, currency: "USD" },
        with:   { aggregate: "a1", entities: [] }
      )
    end.to raise_error(Hecks::Runtime::TypeMismatch,
                       /dispatch takes command facts in with:, not both with: and a flat facts hash/)
  end
end
