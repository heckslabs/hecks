# The Pizzas vertical slice, end to end.
#
# Every example boots a real domain from the folder convention and drives it
# through the door — no test doubles, no reaching past the aggregate. If a rule
# is declared in the bluebook, it is verified here through a dispatch, because
# that is the only way a caller can reach it.
#
# Persistence is bound to Memory for speed ; the Sqlite binding is exercised in
# its own example so the durable path is not left unproven.
require "hecksagain"

RSpec.describe "Pizzas" do
  # No disk. See spec/spec_helper.rb — the domain is composed straight into a
  # registry and bound to Memory, because none of what these examples verify
  # has anything to do with a filesystem.
  let(:runtime) { boot_in_memory }

  def create(name: "Margherita", price_cents: 1200)
    runtime.dispatch("Pizzas::Pizza.CreatePizza", name: name, price_cents: price_cents)
  end

  def topped(**overrides)
    pizza = create
    runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Basil", amount: 3, **overrides)
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
      result = runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")

      expect(result.events.map(&:name)).to eq(["PizzaPurchased"])
      expect(result.state[:customer_name]).to eq("Chris")
      expect(result.state[:status]).to eq("sold")
    end

    it "appends toppings as value objects" do
      pizza = topped
      state = runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Olive", amount: 2).state

      expect(state[:toppings]).to eq([{ name: "Basil", amount: 3 }, { name: "Olive", amount: 2 }])
    end

    it "keeps every emitted event in order" do
      pizza = topped
      runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")

      expect(runtime.events.map(&:name)).to eq(%w[PizzaCreated ToppingAdded PizzaPurchased])
    end
  end

  describe "the rules the bluebook declares" do
    it "refuses a purchase with no toppings" do
      pizza = create
      expect { runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris") }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /at least one topping/)
    end

    it "refuses a second purchase" do
      pizza = topped
      runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")

      expect { runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Someone") }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /still be available/)
    end

    it "refuses a topping on a sold pizza" do
      pizza = topped
      runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")

      expect { runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Late", amount: 1) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /cannot be changed/)
    end

    it "enforces the Topping invariant before the value reaches the pizza" do
      pizza = create
      expect { runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Air", amount: 0) }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /amount must be positive/)

      expect(runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Basil", amount: 1)
                    .state[:toppings].size).to eq(1)
    end

    it "leaves the instance untouched when a command is refused" do
      pizza = topped
      begin
        runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Air", amount: -5)
      rescue Hecksagain::Runtime::InvariantViolation
        # expected
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
      expect { runtime.dispatch("Pizzas::Pizza.Purchase", customer_name: "Chris") }
        .to raise_error(Hecksagain::Runtime::NotFound, /pass id/)
    end

    it "reports an id that does not exist" do
      expect { runtime.dispatch("Pizzas::Pizza.Purchase", id: "pizza-nope", customer_name: "Chris") }
        .to raise_error(Hecksagain::Runtime::NotFound, /no Pizza with id/)
    end
  end

  describe "the persistence binding" do
    # No disk: a bad bind is refused while the registry is being composed, so
    # there is nothing to write and nowhere to write it.
    #
    # This asserted /no persisted_by bind/ and so passed on the wrong error —
    # the ABSENCE of a persistence bind, never the verb mismatch it is named
    # for. `verify!` resolved each bind by calling `repository`, which looks up
    # the aggregate's persisted_by bind and ignores the bind being iterated, so
    # a charged_by bind was never verb-checked. Giving an unbound aggregate the
    # Memory default removed the accident and left the gap visible.
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

    # WIRING IS OVERRIDE, NOT SUBSTRATE. A hecksagon bind changes which adapter
    # answers ; it is not what makes persistence exist. Memory is an ordinary
    # adapter — it declares the persistence port in memory.adapter and
    # implements the same contract — that the runtime always carries, so an
    # aggregate nobody wired still gets a real repository.
    # The default is the one bind nobody declares, so it is the one bind nobody
    # would think to look at. It is reached by NAME from the port, matched
    # against a declaration that arrives by a glob and a class that arrives by a
    # require — all reliable until one is renamed, and unchecked until now the
    # break would have surfaced as `unknown adapter` at first save, on a path the
    # author never wrote.
    it "refuses to boot when the default adapter is not loaded" do
      registry = Hecksagain::Runtime::Registry.new

      expect do
        Hecksagain.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          # MEMORY_ADAPTER deliberately not loaded.
          Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        end
        registry.verify!
      end.to raise_error(
        Hecksagain::Runtime::WiringError,
        /default persistence adapter \(Memory\) is not usable/
      )
    end

    it "gives an aggregate with no bind the internal Memory adapter" do
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
      expect(registry.repository("Pizzas", pizza)).to be_a(Hecksagain::Adapters::Memory)

      # And it is a REAL repository, not a stub that swallows writes.
      runtime.dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita", price_cents: 900)
      expect(registry.repository("Pizzas", pizza).count).to eq(1)
    end
  end
end
