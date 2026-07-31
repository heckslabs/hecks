require "hecksagain"

RSpec.describe "Pizzas" do
  let(:runtime) { boot_in_memory }

  def create(name: "Margherita", price_cents: 1200)
    runtime.dispatch("Pizzas::Pizza.CreatePizza", name: { value: name }, price_cents: { cents: price_cents })
  end

  def topped(**overrides)
    pizza = create
    runtime.dispatch("Pizzas::Pizza.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 }, **overrides)
    pizza
  end

  describe "the domain surface" do
    it "exposes every command as a fully-qualified verb" do
      expect(runtime.verbs).to contain_exactly(
        "Pizzas::Pizza.AddTopping",
        "Pizzas::Pizza.CreatePizza",
        "Pizzas::Pizza.Purchase"
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
      result = runtime.dispatch("Pizzas::Pizza.Purchase", name: pizza.id, customer_name: { value: "Chris" })

      expect(result.events.map(&:name)).to eq(["PizzaPurchased"])
      expect(result.state[:customer_name].to_h).to eq(value: "Chris")
      expect(result.state[:status]).to eq("sold")
    end

    it "appends toppings as value objects" do
      pizza = topped
      state = runtime.dispatch("Pizzas::Pizza.AddTopping", name: pizza.id, topping: { value: "Olive" }, amount: { value: 2 }).state

      expect(state[:toppings].map(&:to_h)).to eq([{ name: "Basil", amount: 3 }, { name: "Olive", amount: 2 }])
    end

    it "keeps every emitted event in order" do
      pizza = topped
      runtime.dispatch("Pizzas::Pizza.Purchase", name: pizza.id, customer_name: { value: "Chris" })

      expect(runtime.events.map(&:name)).to eq(%w[PizzaCreated ToppingAdded PizzaPurchased])
    end
  end

  describe "the rules the bluebook declares" do
    it "refuses a purchase with no toppings" do
      pizza = create
      expect { runtime.dispatch("Pizzas::Pizza.Purchase", name: pizza.id, customer_name: { value: "Chris" }) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /at least one topping/)
    end

    it "refuses a second purchase" do
      pizza = topped
      runtime.dispatch("Pizzas::Pizza.Purchase", name: pizza.id, customer_name: { value: "Chris" })

      expect { runtime.dispatch("Pizzas::Pizza.Purchase", name: pizza.id, customer_name: { value: "Someone" }) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /still be available/)
    end

    it "refuses a topping on a sold pizza" do
      pizza = topped
      runtime.dispatch("Pizzas::Pizza.Purchase", name: pizza.id, customer_name: { value: "Chris" })

      expect { runtime.dispatch("Pizzas::Pizza.AddTopping", name: pizza.id, topping: { value: "Late" }, amount: { value: 1 }) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /cannot be changed/)
    end

    it "enforces the ToppingAmount invariant before the value reaches the pizza" do
      pizza = create
      expect { runtime.dispatch("Pizzas::Pizza.AddTopping", name: pizza.id, topping: { value: "Air" }, amount: { value: 0 }) }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /ToppingAmount .* an amount is positive/)

      expect(runtime.dispatch("Pizzas::Pizza.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 1 })
                    .state[:toppings].size).to eq(1)
    end

    it "leaves the instance untouched when a command is refused" do
      pizza = topped
      begin
        runtime.dispatch("Pizzas::Pizza.AddTopping", name: pizza.id, topping: { value: "Air" }, amount: { value: -5 })
      rescue Hecksagain::Runtime::InvariantViolation
      end

      repository = runtime.registry.repository("Pizzas", runtime.registry.bluebook("Pizzas").aggregate("Pizza"))
      expect(repository.find(pizza.id).toppings.size).to eq(1)
    end
  end

  describe "the door" do
    it "rejects an unknown command" do
      expect { runtime.dispatch("Pizzas::Pizza.Nope") }
        .to raise_error(Hecksagain::Runtime::UnknownVerb, /no command/)
    end

    it "rejects an unqualified verb" do
      expect { runtime.dispatch("Pizza.Purchase") }
        .to raise_error(Hecksagain::Runtime::UnknownVerb, /fully-qualified/)
    end

    it "requires an id for a command that acts on an existing instance" do
      expect { runtime.dispatch("Pizzas::Pizza.Purchase", customer_name: { value: "Chris" }) }
        .to raise_error(Hecksagain::Runtime::NotFound, /pass name/)
    end

    it "reports an id that does not exist" do
      expect { runtime.dispatch("Pizzas::Pizza.Purchase", name: "pizza-nope", customer_name: { value: "Chris" }) }
        .to raise_error(Hecksagain::Runtime::NotFound, /no Pizza with name/)
    end
  end

  describe "the persistence binding" do
    it "refuses a bind whose adapter cannot satisfy the verb" do
      registry = Hecksagain::Runtime::Registry.new

      expect do
        Hecksagain.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
          Hecks.hecksagon("Pizzas") { Pizzas::Pizza.charged_by("Memory") }
        end
        registry.verify!
      end.to raise_error(
        Hecksagain::Runtime::WiringError,
        /Memory implements the persistence port.*cannot satisfy charged_by/m
      )
    end

    it "refuses to boot when the default adapter is not loaded" do
      registry = Hecksagain::Runtime::Registry.new

      expect do
        Hecksagain.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        end
        registry.verify!
      end.to raise_error(
        Hecksagain::Runtime::WiringError,
        /default persistence adapter \(Memory\) is not usable/
      )
    end

    it "gives a domain with no hecksagon the internal Memory adapter" do
      registry = Hecksagain::Runtime::Registry.new

      runtime = Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        Hecksagain::Runtime::Dispatcher.new(registry)
      end

      pizza = registry.bluebook("Pizzas").aggregate("Pizza")
      expect(registry.repository("Pizzas", pizza)).to be_a(Hecksagain::Ports::Persistence::AppendOnly)

      runtime.dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita", name: { value: "Margherita" }, price_cents: { cents: 900 })
      expect(registry.repository("Pizzas", pizza).count).to eq(1)
    end

    it "refuses an unbound aggregate when the domain declares a hecksagon" do
      registry = Hecksagain::Runtime::Registry.new

      expect do
        Hecksagain.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
          Hecks.hecksagon("Pizzas") { Pizzas::Pizza.charged_by("Memory") }
        end

        pizza = registry.bluebook("Pizzas").aggregate("Pizza")
        registry.repository("Pizzas", pizza)
      end.to raise_error(
        Hecksagain::Runtime::WiringError,
        /Pizza has no persisted_by bind.*forgotten decision/m
      )
    end

    it "accepts an aggregate the hecksagon binds to Memory explicitly" do
      registry = Hecksagain::Runtime::Registry.new

      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        Hecks.hecksagon("Pizzas") { Pizzas::Pizza.persisted_by("Memory") }
      end

      pizza = registry.bluebook("Pizzas").aggregate("Pizza")
      expect(registry.repository("Pizzas", pizza)).to be_a(Hecksagain::Ports::Persistence::AppendOnly)
    end
  end
end
