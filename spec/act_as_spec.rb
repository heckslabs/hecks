require "hecks"

# A role temporarily acting as another: Governance's `RoleTransition` says whether it may,
# `Hecks.as_caller` scopes it. Two registries, since the check and the dispatch are separate steps.
RSpec.describe "act_as — a role acting as another, checked against Governance" do
  def governance_runtime
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/governance.bluebook"))
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def pizzas_runtime
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      Hecks.hecksagon("Pizzas") do
        uses_framework "Governance"
        Pizzas::Order.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:governance) { governance_runtime }
  let(:pizzas) { pizzas_runtime }

  # The application-level check, not library code. `Allowed` returns granted and revoked
  # records alike, so a nil `ends_at` is what marks a live grant.
  def transition_granted?(from:, to:)
    rows = governance.query(
      "Governance::RoleTransition.Allowed",
      from_role: { value: from }, to_role: { value: to }
    )
    rows.any? { |row| row[:ends_at].nil? }
  end

  def grant(from:, to:, starts_at: "2026-01-01")
    governance.dispatch_flat(
      "Governance::RoleTransition.Grant",
      from_role: { value: from }, to_role: { value: to }, starts_at: { value: starts_at }
    )
  end

  PIZZA_ARGS = { pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }.freeze

  it "lets a granted role act as another for one nested dispatch, then restores the original" do
    grant(from: "Customer", to: "Chef")
    expect(transition_granted?(from: "Customer", to: "Chef")).to be(true)

    business = pizzas

    created = nil
    Hecks.as_caller(role: "Customer") do
      # `CreatePizza` needs "Chef"; the outer caller is "Customer", so only the nested
      # `as_caller` authorizes this dispatch.
      created = Hecks.as_caller(role: "Chef") do
        business.dispatch_flat("Pizzas::Order.CreatePizza", name: { value: "Margherita" }, **PIZZA_ARGS)
      end
      Hecks.as_caller(role: "Chef") do
        business.dispatch_flat(
          "Pizzas::Order.AddTopping", id: created.instance.id,
          topping: { value: "Basil" }, amount: { value: 1 }
        )
      end

      # Restored: a "Customer"-only command dispatches here, outside the nested block.
      purchased = business.dispatch_flat(
        "Pizzas::Order.Purchase", id: created.instance.id,
        customer_name: { value: "Dana" }, amount: { cents: 1200 }
      )

      expect(purchased.events.map(&:name)).to eq(["PizzaPurchased"])
    end
  end

  # The guarded call an application makes. `dispatched` records whether the block ran, so the
  # refusal test can show the dispatch was never attempted.
  def act_as(from:, to:, dispatched:)
    raise "not authorized: #{from} may not act as #{to}" unless transition_granted?(from: from, to: to)

    Hecks.as_caller(role: to) do
      dispatched[:ran] = true
      yield
    end
  end

  it "refuses at the application check, before any dispatch happens, when Governance grants nothing" do
    business = pizzas
    dispatched = { ran: false }

    expect(transition_granted?(from: "Customer", to: "Chef")).to be(false)
    expect do
      Hecks.as_caller(role: "Customer") do
        act_as(from: "Customer", to: "Chef", dispatched: dispatched) do
          business.dispatch_flat("Pizzas::Order.CreatePizza", name: { value: "Refused" }, **PIZZA_ARGS)
        end
      end
    end.to raise_error(/not authorized/)

    expect(dispatched[:ran]).to be(false)
    expect(business.registry.repository("Pizzas", business.registry.bluebook("Pizzas").aggregate("Order")).all)
      .to be_empty
  end

  it "a revoked transition is no longer granted, so the app-level check refuses again" do
    created = grant(from: "Customer", to: "Chef")
    expect(transition_granted?(from: "Customer", to: "Chef")).to be(true)

    governance.dispatch_flat("Governance::RoleTransition.Revoke", id: created.instance.id, ends_at: { value: "2026-06-01" })

    expect(transition_granted?(from: "Customer", to: "Chef")).to be(false)
  end

  it "an unauthorized nested act_as still refuses at the runtime, same as any other role mismatch" do
    business = pizzas

    expect do
      Hecks.as_caller(role: "Customer") do
        business.dispatch_flat("Pizzas::Order.CreatePizza", name: { value: "NeverGranted" }, **PIZZA_ARGS)
      end
    end.to raise_error(Hecks::Runtime::Unauthorized)
  end
end
