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
require "tmpdir"
require "fileutils"

RSpec.describe "Pizzas" do
  # A domain directory identical to examples/pizzas, but bound to whichever
  # adapter the example asks for.
  def boot(adapter: "Memory")
    source = File.expand_path("../examples/pizzas/bluebook", __dir__)
    dir    = Dir.mktmpdir("hecksagain-")
    target = File.join(dir, "bluebook")
    FileUtils.mkdir_p(target)

    FileUtils.cp(Dir[File.join(source, "*")], target)
    File.write(File.join(target, "pizzas.hecksagon"), <<~HECKSAGON)
      Hecks.hecksagon "Pizzas" do
        Pizzas::Pizza.persisted_by("#{adapter}")
      end
    HECKSAGON

    # Memory needs no configuration, so it has NO world block. A world naming a
    # field its adapter does not declare is refused at boot - which is the
    # point of declaring fields on the adapter.
    File.delete(File.join(target, "pizzas.world")) if adapter == "Memory"

    @dirs ||= []
    @dirs << dir
    Hecks.boot(dir, shared: SHARED)
  end

  after { @dirs&.each { |dir| FileUtils.remove_entry(dir) } }

  let(:runtime) { boot }

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
    it "survives a reboot when bound to Sqlite" do
      runtime = boot(adapter: "Sqlite")
      pizza   = runtime.dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita", price_cents: 1200)
      runtime.dispatch("Pizzas::Pizza.AddTopping", id: pizza.id, name: "Basil", amount: 3)
      runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")

      # Same directory, brand new registry, adapters and all.
      rebooted  = Hecks.boot(@dirs.last, shared: SHARED)
      aggregate = rebooted.registry.bluebook("Pizzas").aggregate("Pizza")
      stored    = rebooted.registry.repository("Pizzas", aggregate).find(pizza.id)

      expect(stored.status).to eq("sold")
      expect(stored.customer_name).to eq("Chris")
      expect(stored.toppings).to eq([{ name: "Basil", amount: 3 }])
    end

    it "refuses a bind whose adapter cannot satisfy the verb" do
      source = File.expand_path("../examples/pizzas/bluebook", __dir__)
      dir    = Dir.mktmpdir("hecksagain-bad-")
      target = File.join(dir, "bluebook")
      FileUtils.mkdir_p(target)
      FileUtils.cp(Dir[File.join(source, "*")], target)

      File.write(File.join(target, "pizzas.hecksagon"), <<~HECKSAGON)
        Hecks.hecksagon "Pizzas" do
          Pizzas::Pizza.charged_by("Sqlite")
        end
      HECKSAGON

      expect { Hecks.boot(dir, shared: SHARED) }.to raise_error(Hecksagain::Runtime::WiringError, /no persisted_by bind/)
    ensure
      FileUtils.remove_entry(dir) if dir
    end
  end
end
