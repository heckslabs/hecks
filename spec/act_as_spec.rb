require "hecks"

# A role temporarily acting as another: Governance's `RoleTransition` says whether it may,
# `Hecks.as_caller` scopes it. Two registries, since the check and the dispatch are separate steps.
RSpec.describe "act_as — a role acting as another, checked against Governance" do
  # A bound runtime over a fresh registry holding what the block declares, on the in-memory ports.
  def booted_runtime(&)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |port| Kernel.load(port) }
      yield
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def persist_governance
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def governance_runtime
    booted_runtime do
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/governance.bluebook"))
      persist_governance
    end
  end

  def pizzas_runtime
    booted_runtime do
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      Hecks.hecksagon("Pizzas") do
        attaches "Governance"
        Pizzas::Order.persisted_by("Memory")
      end
      persist_governance
    end
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

  def create_pizza(business, name)
    business.dispatch_flat("Pizzas::Order.CreatePizza", name: { value: name }, **PIZZA_ARGS)
  end

  def create_as_chef(business) = Hecks.as_caller(role: "Chef") { create_pizza(business, "Margherita") }

  def add_basil_as_chef(business, created)
    Hecks.as_caller(role: "Chef") do
      business.dispatch_flat(
        "Pizzas::Order.AddTopping", id: created.instance.id,
        topping: { value: "Basil" }, amount: { value: 1 }
      )
    end
  end

  def purchase(business, created)
    business.dispatch_flat(
      "Pizzas::Order.Purchase", id: created.instance.id,
      customer_name: { value: "Dana" }, amount: { cents: 1200 }
    )
  end

  def purchase_with_nested_chef(business)
    Hecks.as_caller(role: "Customer") do
      # `CreatePizza` needs "Chef"; the outer caller is "Customer", so only the nested
      # `as_caller` authorizes this dispatch.
      created = create_as_chef(business)
      add_basil_as_chef(business, created)
      # Restored: a "Customer"-only command dispatches here, outside the nested block.
      purchase(business, created)
    end
  end

  it "lets a granted role act as another for one nested dispatch, then restores the original", :aggregate_failures do
    grant(from: "Customer", to: "Chef")
    expect(transition_granted?(from: "Customer", to: "Chef")).to be(true)

    purchased = purchase_with_nested_chef(pizzas)

    expect(purchased.events.map(&:name)).to eq(["PizzaPurchased"])
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

  def refused_creation(business, dispatched)
    Hecks.as_caller(role: "Customer") do
      act_as(from: "Customer", to: "Chef", dispatched: dispatched) { create_pizza(business, "Refused") }
    end
  end

  def pizza_orders(business)
    business.registry.repository("Pizzas", business.registry.bluebook("Pizzas").aggregate("Order")).all
  end

  it "refuses at the application check when Governance grants nothing", :aggregate_failures do
    expect(transition_granted?(from: "Customer", to: "Chef")).to be(false)
    expect { refused_creation(pizzas, { ran: false }) }.to raise_error(/not authorized/)
  end

  it "refuses before any dispatch happens, so nothing is created", :aggregate_failures do
    business = pizzas
    dispatched = { ran: false }

    expect { refused_creation(business, dispatched) }.to raise_error(/not authorized/)
    expect(dispatched[:ran]).to be(false)
    expect(pizza_orders(business)).to be_empty
  end

  it "a revoked transition is no longer granted, so the app-level check refuses again", :aggregate_failures do
    created = grant(from: "Customer", to: "Chef")
    expect(transition_granted?(from: "Customer", to: "Chef")).to be(true)

    governance.dispatch_flat("Governance::RoleTransition.Revoke", id: created.instance.id, ends_at: { value: "2026-06-01" })

    expect(transition_granted?(from: "Customer", to: "Chef")).to be(false)
  end

  it "an unauthorized nested act_as still refuses at the runtime, same as any other role mismatch" do
    expect { Hecks.as_caller(role: "Customer") { create_pizza(pizzas, "NeverGranted") } }
      .to raise_error(Hecks::Runtime::Unauthorized)
  end
end
