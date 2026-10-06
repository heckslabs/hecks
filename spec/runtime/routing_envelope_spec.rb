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

  let(:runtime) { boot_banking }

  def register_customer(reference)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: reference },
                          name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
  end

  def logged_visit
    register_customer("c")
    runtime.dispatch_flat("Banking::SafeDepositBox.Rent", customer: "c", branch_code: { value: "DOWNTOWN" },
                          box_number: { value: 12 }, size: { value: "medium" })
    runtime.dispatch_flat("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                          date: { value: "2026-01-05" }, sequence: { value: 1 })
  end

  def annotate(to:, with: { note: { text: "Flagged" } })
    runtime.dispatch("Banking::SafeDepositBox.Visit.Annotate", to: to, with: with)
  end

  describe "an entity command's envelope" do
    let(:entity_route) { { aggregate: "DOWNTOWN:12", entity: "2026-01-05:1" } }

    before { logged_visit }

    it "routes aggregate and entity identities separately from Annotate's facts", :aggregate_failures do
      result = annotate(to: entity_route)

      expect(Banking::SafeDepositBox.find("DOWNTOWN:12").visits.first[:note].to_h).to eq(text: "Flagged")
      expect(result.execution_plan).not_to be_state_independent
      expect([result.execution_plan.strategy_for, result.persistence_outcome.status])
        .to eq([:load_apply_validate_store, :saved])
    end

    it "refuses receiver identity smuggled back into an explicit payload" do
      expect { annotate(to: entity_route, with: { date: { value: "2026-01-05" }, note: { text: "Flagged" } }) }
        .to raise_error(Hecks::Runtime::UnknownArgument, /Annotate does not declare date.*it takes note/)
    end

    it "refuses an incomplete entity routing envelope before touching state" do
      expect { annotate(to: "DOWNTOWN:12") }
        .to raise_error(Hecks::Runtime::TypeMismatch, /needs 1 entity identity.*got 0/)
    end
  end

  # An aggregate-only envelope (`entities: []` or absent) on an entity_depth 0 command passes
  # the `entities.size != entity_depth` check trivially; Rust refuses it outright, so must Ruby.
  describe "an aggregate command's envelope" do
    def open_account(ref: "c1", number: "a1")
      register_customer(ref)
      runtime.dispatch_flat("Banking::Account.Open", customer: ref, number: { value: number },
                            kind: { name: "current" }, daily_limit: { cents: 1_000 })
    end

    def credit(to:)
      facts = { amount: { cents: 100, currency: "USD" }, narrative: { text: "x" } }
      runtime.dispatch("Banking::Account.Credit", to: to, with: facts)
    end

    before { open_account }

    it "refuses entities: [] on an aggregate-level command's to:, not lets it reach the command's own validation" do
      expect { credit(to: { aggregate: "a1", entities: [] }) }
        .to raise_error(Hecks::Runtime::TypeMismatch, /entity route requires at least one entity identity/)
    end

    it "refuses an entity/entities-less aggregate Hash the same way" do
      expect { credit(to: { aggregate: "a1" }) }
        .to raise_error(Hecks::Runtime::TypeMismatch, /entity route requires at least one entity identity/)
    end

    it "still accepts the bare aggregate identity string for the same command" do
      expect { credit(to: "a1") }.not_to raise_error
    end

    # Rust once judged `with:`'s value as the facts and refused UnknownArgument; both must now
    # refuse TypeMismatch (pinned Rust-side in rust/src/kernel/routing.rs).
    it "refuses with: carrying a routing-shaped object beside a loose legacy fact" do
      route = { aggregate: "a1", entities: [] }

      expect { runtime.dispatch_flat("Banking::Account.Credit", amount: { cents: 100, currency: "USD" }, with: route) }
        .to raise_error(Hecks::Runtime::TypeMismatch,
                        /dispatch takes command facts in with:, not both with: and a flat facts hash/)
    end
  end
end
