require "hecks"

# §2's demonstration: a caller acting under one role, temporarily assuming
# another to dispatch a command that role does not itself hold — checked
# against Governance's `RoleTransition`, then scoped with
# `Hecks.as_caller`. TWO SEPARATE REGISTRIES, on purpose: Governance's
# own, and Pizzas' — checking authority and dispatching a business command
# are two independent steps an application already coordinates in plain
# Ruby, so nothing here composes them into one registry.
#
# NO CHANGE TO CommandInterpreter, Dispatcher, OR CommandRules::Authorization
# backs this — `Caller.as` already scopes a role to a nested dispatch and
# restores it after, via ordinary Ruby `ensure`, and `refuse_role_mismatch`
# already does nothing when no caller is bound. This spec is the proof: the
# pattern composes out of primitives that already exist.
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
        ::Governance::RoleAssignment.persisted_by("Memory")
        ::Governance::RoleTransition.persisted_by("Memory")
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
        ::Pizzas::Order.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        ::Governance::RoleAssignment.persisted_by("Memory")
        ::Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:governance) { governance_runtime }
  let(:pizzas) { pizzas_runtime }

  # THE APPLICATION-LEVEL CHECK. Not library code — the same reasoning
  # `Ports::IdentityGeneration`'s own spec demonstrates a real dispatch
  # against, rather than inventing facade machinery for a pattern that
  # composes out of what already exists. `Allowed` returns the record
  # whether granted or revoked (see governance.bluebook's own comment on
  # the query) — the caller reads `ends_at`, same as `AssignmentsForActor`.
  def transition_granted?(from:, to:)
    rows = governance.query(
      "Governance::RoleTransition.Allowed",
      from_role: { value: from }, to_role: { value: to }
    )
    rows.any? { |row| row[:ends_at].nil? }
  end

  def grant(from:, to:)
    governance.dispatch(
      "Governance::RoleTransition.Grant",
      from_role: { value: from }, to_role: { value: to }
    )
  end

  PIZZA_ARGS = { pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }.freeze

  it "lets a granted role act as another for one nested dispatch, then restores the original" do
    grant(from: "Customer", to: "Chef")
    expect(transition_granted?(from: "Customer", to: "Chef")).to be(true)

    business = pizzas

    created = nil
    Hecks.as_caller(role: "Customer") do
      # `CreatePizza` needs "Chef" — the OUTER caller is "Customer" and does
      # not hold it. The nested `as_caller` is what makes this dispatch
      # authorized at all.
      created = Hecks.as_caller(role: "Chef") do
        business.dispatch("Pizzas::Order.CreatePizza", name: { value: "Margherita" }, **PIZZA_ARGS)
      end
      Hecks.as_caller(role: "Chef") do
        business.dispatch(
          "Pizzas::Order.AddTopping", id: created.instance.id,
          topping: { value: "Basil" }, amount: { value: 1 }
        )
      end

      # RESTORED. `Caller.current` is "Customer" again the moment the
      # nested block returns — proved by dispatching a "Customer"-only
      # command right here, still inside the OUTER as_caller, with no
      # nested block in the way.
      purchased = business.dispatch(
        "Pizzas::Order.Purchase", id: created.instance.id,
        customer_name: { value: "Dana" }, amount: { cents: 1200 }
      )

      expect(purchased.events.map(&:name)).to eq(["PizzaPurchased"])
    end
  end

  # THE GUARDED CALL an application actually makes: check Governance, and
  # only reach the nested dispatch if it says yes. `dispatched` records
  # whether the block ran at all, so the refusal path can prove the
  # dispatch was never attempted — not merely that it would have failed.
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
          business.dispatch("Pizzas::Order.CreatePizza", name: { value: "Refused" }, **PIZZA_ARGS)
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

    governance.dispatch("Governance::RoleTransition.Revoke", id: created.instance.id, ends_at: { value: "2026-06-01" })

    expect(transition_granted?(from: "Customer", to: "Chef")).to be(false)
  end

  it "an unauthorized nested act_as still refuses at the runtime, same as any other role mismatch" do
    business = pizzas

    expect do
      Hecks.as_caller(role: "Customer") do
        business.dispatch("Pizzas::Order.CreatePizza", name: { value: "NeverGranted" }, **PIZZA_ARGS)
      end
    end.to raise_error(Hecks::Runtime::Unauthorized)
  end
end
