require "hecks"

RSpec.describe "Pizzas" do
  let(:runtime) { boot_in_memory }

  def create(name: "Margherita", price_cents: 1200, size: "large")
    runtime.dispatch("Pizzas::Order.CreatePizza",
                     name: { value: name }, pizza: { price_cents: { cents: price_cents }, size: { value: size } })
  end

  def topped(**overrides)
    pizza = create
    runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 }, **overrides)
    pizza
  end

  describe "asking through the nested value object" do
    # The dotted-path queries, answered by the REFERENCE interpreter here —
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

    it "starts a list attribute empty and a defaulted attribute at its default" do
      pizza = create
      expect(pizza.state[:toppings]).to eq([])
      expect(pizza.state[:status]).to eq("available")
    end
  end

  describe "selling a pizza" do
    it "emits PizzaPurchased and records the customer" do
      pizza  = topped
      result = runtime.dispatch("Pizzas::Order.Purchase", name: pizza.id, customer_name: { value: "Chris" },
amount: { cents: 1200 })

      expect(result.events.map(&:name)).to eq(["PizzaPurchased"])
      expect(result.state[:customer_name].to_h).to eq(value: "Chris")
      expect(result.state[:status]).to eq("sold")
    end

    it "appends toppings as value objects" do
      pizza = topped
      state = runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Olive" },
amount: { value: 2 }).state

      expect(state[:toppings].map(&:to_h)).to eq([{ name: "Basil", amount: 3 }, { name: "Olive", amount: 2 }])
    end

    it "keeps every emitted event in order" do
      pizza = topped
      runtime.dispatch("Pizzas::Order.Purchase", name: pizza.id, customer_name: { value: "Chris" }, amount: { cents: 1200 })

      expect(runtime.events.map(&:name)).to eq(%w[PizzaCreated ToppingAdded PizzaPurchased])
    end
  end

  describe "the rules the bluebook declares" do
    it "refuses a purchase with no toppings" do
      pizza = create
      expect { runtime.dispatch("Pizzas::Order.Purchase", name: pizza.id, customer_name: { value: "Chris" }, amount: { cents: 1200 }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /at least one topping/)
    end

    it "refuses a second purchase" do
      pizza = topped
      runtime.dispatch("Pizzas::Order.Purchase", name: pizza.id, customer_name: { value: "Chris" }, amount: { cents: 1200 })

      expect { runtime.dispatch("Pizzas::Order.Purchase", name: pizza.id, customer_name: { value: "Someone" }, amount: { cents: 1200 }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /still be available/)
    end

    it "refuses a topping on a sold pizza" do
      pizza = topped
      runtime.dispatch("Pizzas::Order.Purchase", name: pizza.id, customer_name: { value: "Chris" }, amount: { cents: 1200 })

      expect { runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Late" }, amount: { value: 1 }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /cannot be changed/)
    end

    it "enforces the ToppingAmount invariant before the value reaches the pizza" do
      pizza = create
      expect { runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Air" }, amount: { value: 0 }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /ToppingAmount .* an amount is positive/)

      expect(runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 1 })
                    .state[:toppings].size).to eq(1)
    end

    it "leaves the instance untouched when a command is refused" do
      pizza = topped
      begin
        runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Air" }, amount: { value: -5 })
      rescue Hecks::Runtime::InvariantViolation
      end

      repository = runtime.registry.repository("Pizzas", runtime.registry.bluebook("Pizzas").aggregate("Order"))
      expect(repository.find(pizza.id).toppings.size).to eq(1)
    end
  end

  describe "the door" do
    it "rejects an unknown command" do
      expect { runtime.dispatch("Pizzas::Order.Nope") }
        .to raise_error(Hecks::Runtime::UnknownVerb, /no command/)
    end

    it "rejects an unqualified verb" do
      expect { runtime.dispatch("Order.Purchase") }
        .to raise_error(Hecks::Runtime::UnknownVerb, /fully-qualified/)
    end

    it "requires an id for a command that acts on an existing instance" do
      expect { runtime.dispatch("Pizzas::Order.Purchase", customer_name: { value: "Chris" }, amount: { cents: 1200 }) }
        .to raise_error(Hecks::Runtime::NotFound, /pass name/)
    end

    it "reports an id that does not exist" do
      expect { runtime.dispatch("Pizzas::Order.Purchase", name: "pizza-nope", customer_name: { value: "Chris" }, amount: { cents: 1200 }) }
        .to raise_error(Hecks::Runtime::NotFound, /no Order with name/)
    end
  end

  describe "the persistence binding" do
    it "refuses a bind whose adapter cannot satisfy the verb" do
      registry = Hecks::Runtime::Registry.new

      expect do
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
          Hecks.hecksagon("Pizzas") do
            uses_framework "Governance"
            Pizzas::Order.charged_by("Memory")
          end
          Hecks.hecksagon("Governance") do
            Governance::RoleAssignment.persisted_by("Memory")
            Governance::RoleTransition.persisted_by("Memory")
          end
        end
        registry.verify!
      end.to raise_error(
        Hecks::Runtime::WiringError,
        /Memory implements the persistence port.*cannot satisfy charged_by/m
      )
    end

    it "refuses to boot when the default adapter is not loaded" do
      registry = Hecks::Runtime::Registry.new

      expect do
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        end
        registry.verify!
      end.to raise_error(
        Hecks::Runtime::WiringError,
        /default persistence adapter \(Memory\) is not usable/
      )
    end

    it "gives a domain with no hecksagon the internal Memory adapter" do
      registry = Hecks::Runtime::Registry.new

      runtime = Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        Hecks::Runtime::Dispatcher.new(registry)
      end

      pizza = registry.bluebook("Pizzas").aggregate("Order")
      expect(registry.repository("Pizzas", pizza)).to be_a(Hecks::Ports::Persistence::AppendOnly)

      # `name:` was written TWICE here — once as a bare string, once as the value
      # object — and Ruby warned on every run while silently keeping the second.
      runtime.dispatch("Pizzas::Order.CreatePizza",
                       name: { value: "Margherita" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } })
      expect(registry.repository("Pizzas", pizza).count).to eq(1)
    end

    it "refuses an unbound aggregate when the domain declares a hecksagon" do
      registry = Hecks::Runtime::Registry.new

      expect do
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
          Hecks.hecksagon("Pizzas") do
            uses_framework "Governance"
            Pizzas::Order.charged_by("Memory")
          end
          Hecks.hecksagon("Governance") do
            Governance::RoleAssignment.persisted_by("Memory")
            Governance::RoleTransition.persisted_by("Memory")
          end
        end

        pizza = registry.bluebook("Pizzas").aggregate("Order")
        registry.repository("Pizzas", pizza)
      end.to raise_error(
        Hecks::Runtime::WiringError,
        /Order has no persisted_by bind.*forgotten decision/m
      )
    end

    it "accepts an aggregate the hecksagon binds to Memory explicitly" do
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
      end

      pizza = registry.bluebook("Pizzas").aggregate("Order")
      expect(registry.repository("Pizzas", pizza)).to be_a(Hecks::Ports::Persistence::AppendOnly)
    end
  end
end
