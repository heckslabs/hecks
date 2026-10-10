require "hecks"

RSpec.describe "Pizzas" do
  let(:runtime) { boot_in_memory }

  def create(name: "Margherita", price_cents: 1200, size: "large")
    runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                          name: { value: name }, pizza: { price_cents: { cents: price_cents }, size: { value: size } })
  end

  def topped(**overrides)
    pizza = create
    runtime.dispatch_flat("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 },
**overrides)
    pizza
  end

  def add_topping(pizza, topping, amount)
    runtime.dispatch_flat("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: topping }, amount: { value: amount })
  end

  def purchase_by_id(id, customer = "Chris")
    runtime.dispatch_flat("Pizzas::Order.Purchase", name: id, customer_name: { value: customer }, amount: { cents: 1200 })
  end

  def purchase(pizza, customer = "Chris") = purchase_by_id(pizza.id, customer)

  def order_repository
    runtime.registry.repository("Pizzas", runtime.registry.bluebook("Pizzas").aggregate("Order"))
  end

  def load_pizzas_with_memory
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
     InMemoryDomain::PRISM_ADAPTER, InMemoryDomain::PIZZAS_BLUEBOOK].each { |file| Kernel.load(file) }
  end

  def pizzas_charged_wiring
    proc do
      attaches "Governance"
      Pizzas::Order.charged_by("Memory")
    end
  end

  def governance_wiring
    proc do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  # Pizzas wired to a Memory `charged_by` bind, which the persistence port cannot satisfy.
  def load_charged_pizzas(registry)
    pizzas = pizzas_charged_wiring
    governance = governance_wiring
    Hecks.with_registry(registry) do
      load_pizzas_with_memory
      Hecks.hecksagon("Pizzas", &pizzas)
      Hecks.hecksagon("Governance", &governance)
    end
  end

  def verified_charged_pizzas(registry)
    load_charged_pizzas(registry)
    registry.verify!
  end

  def verified_pizzas_without_memory(registry)
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::PRISM_ADAPTER, InMemoryDomain::PIZZAS_BLUEBOOK].each { |file| Kernel.load(file) }
    end
    registry.verify!
  end

  def memory_pizzas_runtime(registry)
    Hecks.with_registry(registry) do
      load_pizzas_with_memory
      Hecks::Runtime::Dispatcher.new(registry)
    end
  end

  def load_persisted_pizzas(registry)
    wiring = proc do
      attaches "Governance"
      Pizzas::Order.persisted_by("Memory")
    end
    Hecks.with_registry(registry) do
      load_pizzas_with_memory
      Hecks.hecksagon("Pizzas", &wiring)
    end
  end

  describe "asking through the nested value object" do
    # The dotted-path queries, answered by the reference interpreter here —
    # the same declarations answer identically through Postgres against the
    # live example domain, which is the whole point of FieldPath being one
    # walk. Margherita costs 1200, Bare 900 (created below).
    it "CostingLessThan reaches pizza.price_cents.cents with a caller-supplied ceiling" do
      create(name: "Margherita", price_cents: 1200)
      create(name: "Bare", price_cents: 900)

      rows = runtime.query("Pizzas::Order.CostingLessThan", ceiling: { cents: 1000 })
      expect(rows.map { |row| row[:id] }).to eq(["Bare"])
    end

    it "Expensive compares the nested member against its own literal" do
      create(name: "Margherita", price_cents: 1200)
      create(name: "Bare", price_cents: 900)

      rows = runtime.query("Pizzas::Order.Expensive")
      expect(rows.map { |row| row[:id] }).to eq(["Margherita"])
    end
  end

  describe "the domain surface" do
    it "exposes every command as a fully-qualified verb" do
      # `include`, not `contain_exactly` — `boot_in_memory` now attaches
      # Governance too (S8: `role` is only real access control once
      # Governance can check it), so its own verbs are on the surface as
      # well. This test is about Pizza's own commands, not the absence
      # of anything else's.
      expect(runtime.verbs).to include(
        "Pizzas::Order.AddTopping",
        "Pizzas::Order.CreatePizza",
        "Pizzas::Order.Purchase"
      )
    end

    it "starts a list attribute empty and a defaulted attribute at its default", :aggregate_failures do
      pizza = create
      expect(pizza.state[:toppings]).to eq([])
      expect(pizza.state[:status]).to eq("available")
    end
  end

  describe "selling a pizza" do
    it "emits PizzaPurchased and records the customer", :aggregate_failures do
      result = purchase(topped)

      expect(result.events.map(&:name)).to eq(["PizzaPurchased"])
      expect(result.state[:customer_name].to_h).to eq(value: "Chris")
      expect(result.state[:status]).to eq("sold")
    end

    it "appends toppings as value objects" do
      state = add_topping(topped, "Olive", 2).state

      expect(state[:toppings].map(&:to_h)).to eq([{ name: "Basil", amount: 3 }, { name: "Olive", amount: 2 }])
    end

    it "keeps every emitted event in order" do
      purchase(topped)

      expect(runtime.events.map(&:name)).to eq(%w[PizzaCreated ToppingAdded PizzaPurchased])
    end
  end

  describe "the rules the bluebook declares" do
    it "refuses a purchase with no toppings" do
      pizza = create
      expect { purchase(pizza) }.to raise_error(Hecks::Runtime::GivenNotMet, /at least one topping/)
    end

    # S10, ADR 0025 — Purchase/AddTopping's own "still available"/"cannot
    # be changed" givens moved to `from: "available"` on the command
    # itself; the refusal is LifecycleRefused now, not GivenNotMet.
    it "refuses a second purchase" do
      pizza = topped
      purchase(pizza)

      expect { purchase(pizza, "Someone") }
        .to raise_error(Hecks::Runtime::LifecycleRefused, /moves it only from "available"/)
    end

    it "refuses a topping on a sold pizza" do
      pizza = topped
      purchase(pizza)

      expect { add_topping(pizza, "Late", 1) }
        .to raise_error(Hecks::Runtime::LifecycleRefused, /moves it only from "available"/)
    end

    it "enforces the ToppingAmount invariant before the value reaches the pizza", :aggregate_failures do
      pizza = create
      expect { add_topping(pizza, "Air", 0) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /ToppingAmount .* an amount is positive/)

      expect(add_topping(pizza, "Basil", 1).state[:toppings].size).to eq(1)
    end

    it "leaves the instance untouched when a command is refused", :aggregate_failures do
      pizza = topped
      expect { add_topping(pizza, "Air", -5) }.to raise_error(Hecks::Runtime::InvariantViolation)

      expect(order_repository.find(pizza.id).toppings.size).to eq(1)
    end
  end

  describe "the entry point" do
    it "rejects an unknown command" do
      expect { runtime.dispatch("Pizzas::Order.Nope") }
        .to raise_error(Hecks::Runtime::UnknownVerb, /no command/)
    end

    it "rejects an unqualified verb" do
      expect { runtime.dispatch("Order.Purchase") }
        .to raise_error(Hecks::Runtime::UnknownVerb, /fully-qualified/)
    end

    it "requires an id for a command that acts on an existing instance" do
      expect { runtime.dispatch_flat("Pizzas::Order.Purchase", customer_name: { value: "Chris" }, amount: { cents: 1200 }) }
        .to raise_error(Hecks::Runtime::NotFound, /pass name/)
    end

    it "reports an id that does not exist" do
      expect { purchase_by_id("pizza-nope") }
        .to raise_error(Hecks::Runtime::NotFound, /no Order with name/)
    end
  end

  describe "the persistence binding" do
    it "refuses a bind whose adapter cannot satisfy the verb" do
      registry = Hecks::Runtime::Registry.new
      message = /Memory implements the persistence port.*cannot satisfy charged_by/m

      expect { verified_charged_pizzas(registry) }.to raise_error(Hecks::Runtime::WiringError, message)
    end

    it "refuses to boot when the default adapter is not loaded" do
      registry = Hecks::Runtime::Registry.new
      message = /default persistence adapter \(Memory\) is not usable/

      expect { verified_pizzas_without_memory(registry) }.to raise_error(Hecks::Runtime::WiringError, message)
    end

    it "gives a domain with no hecksagon the internal Memory adapter" do
      registry = Hecks::Runtime::Registry.new
      memory_pizzas_runtime(registry)

      pizza = registry.bluebook("Pizzas").aggregate("Order")
      expect(registry.repository("Pizzas", pizza)).to be_a(Hecks::Ports::Persistence::AppendOnly)
    end

    it "stores what a domain with no hecksagon dispatches in the internal Memory adapter" do
      registry = Hecks::Runtime::Registry.new
      runtime = memory_pizzas_runtime(registry)

      # `name:` was written twice here — once as a bare string, once as the value
      # object — and Ruby warned on every run while silently keeping the second.
      runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                            name: { value: "Margherita" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } })
      expect(registry.repository("Pizzas", registry.bluebook("Pizzas").aggregate("Order")).count).to eq(1)
    end

    it "refuses an unbound aggregate when the domain declares a hecksagon" do
      registry = Hecks::Runtime::Registry.new
      load_charged_pizzas(registry)
      order = registry.bluebook("Pizzas").aggregate("Order")

      expect { registry.repository("Pizzas", order) }
        .to raise_error(Hecks::Runtime::WiringError, /Order has no persisted_by bind.*forgotten decision/m)
    end

    it "accepts an aggregate the hecksagon binds to Memory explicitly" do
      registry = Hecks::Runtime::Registry.new
      load_persisted_pizzas(registry)

      pizza = registry.bluebook("Pizzas").aggregate("Order")
      expect(registry.repository("Pizzas", pizza)).to be_a(Hecks::Ports::Persistence::AppendOnly)
    end
  end
end
