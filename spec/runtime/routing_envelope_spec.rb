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

  # BUG#18 — a routing envelope naming only the aggregate (`entities: []`,
  # or `entity`/`entities` absent altogether) on an AGGREGATE-level command
  # (entity_depth 0) used to satisfy `envelope`'s own `entities.size !=
  # entity_depth` check trivially (`0 != 0` is false) and reach the
  # command's own validation instead of being refused as a malformed
  # route — Rust's `RoutingEnvelope::from_json` always refused this Hash
  # shape outright, unconditionally, regardless of entity_depth. Both now
  # refuse at the same point, TypeMismatch, matching Rust's own wording.
  def open_account(runtime, ref: "c1", number: "a1")
    runtime.dispatch("Banking::Customer.Register", reference: { value: ref },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: ref, number: { value: number },
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

  # The `with:` half of the same bug — Ruby already refused this
  # combination (TypeMismatch, "with: plus loose kwargs" — unrelated to
  # what `with:` actually contains), but Rust silently dropped the
  # sibling fact and judged `with:`'s own value as the facts instead,
  # refusing UnknownArgument — a different KIND for the identical
  # malformed step (rust/src/kernel/routing.rs's own regression test,
  # `refuses_with_beside_a_sibling_legacy_fact_the_same_as_ruby_does`,
  # pins the Rust side of this same alignment).
  it "refuses with: carrying a routing-shaped object beside a loose legacy fact" do
    runtime = boot_banking
    open_account(runtime)

    expect do
      runtime.dispatch(
        "Banking::Account.Credit",
        amount: { cents: 100, currency: "USD" },
        with:   { aggregate: "a1", entities: [] }
      )
    end.to raise_error(Hecks::Runtime::TypeMismatch,
                       /dispatch takes command facts in with:, not both with: and loose keyword arguments/)
  end
end
