# The constructed classes — a domain used as ordinary Ruby.
#
# `aggregate "Pizza"` builds a real class while it reads the bluebook, so these
# examples never mention dispatch. That is the point: dispatch is plumbing, and
# a domain author should never type it.
require "hecksagain"
require "tmpdir"
require "fileutils"

RSpec.describe "a constructed aggregate" do
  def boot(adapter: "Memory")
    source = File.expand_path("../examples/pizzas/bluebook", __dir__)
    dir    = Dir.mktmpdir("hecksagain-class-")
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

  before { boot }
  after  { @dirs&.each { |dir| FileUtils.remove_entry(dir) } }

  it "names the domain and its aggregates" do
    expect(Pizzas.aggregates).to eq(["Pizza"])
    expect(Pizzas.vision).to include("sell it to a customer")
  end

  it "turns commands into snake_case methods" do
    expect(Pizza.commands).to eq(%w[add_topping create_pizza purchase])
  end

  it "is a real class, not a stand-in" do
    expect(Pizza).to be_a(Class)
    expect(Pizza.ancestors).to include(Hecksagain::Aggregate)
  end

  describe "a creating command" do
    it "is a class method returning the new record" do
      pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)

      expect(pizza).to be_a(Pizza)
      expect(pizza.name).to eq("Margherita")
      expect(pizza.price_cents).to eq(1200)
      expect(pizza.status).to eq("available")
      expect(pizza.toppings).to eq([])
    end
  end

  describe "a command that references its aggregate" do
    # Identity is already known, so it is never passed by hand.
    it "is an instance method that never asks for an id" do
      pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)
      pizza.add_topping(name: "Basil", amount: 3)

      expect(pizza.toppings).to eq([{ name: "Basil", amount: 3 }])
    end

    it "returns self, so commands chain" do
      pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)
              .add_topping(name: "Basil", amount: 3)
              .add_topping(name: "Olive", amount: 2)
              .purchase(customer_name: "Chris")

      expect(pizza.status).to eq("sold")
      expect(pizza.customer_name).to eq("Chris")
      expect(pizza.toppings.size).to eq(2)
    end
  end

  describe "reading" do
    it "finds, lists, and counts through the bound adapter" do
      pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)

      expect(Pizza.count).to eq(1)
      expect(Pizza.find(pizza.id).name).to eq("Margherita")
      expect(Pizza.all.map(&:id)).to eq([pizza.id])
      expect(Pizza.find("nope")).to be_nil
    end

    it "reports the events one instance announced" do
      pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)
              .add_topping(name: "Basil", amount: 3)
              .purchase(customer_name: "Chris")

      expect(pizza.events.map(&:name)).to eq(%w[PizzaCreated ToppingAdded PizzaPurchased])
      expect(pizza.events.last.name).to eq("PizzaPurchased")
    end
  end

  describe "the rules still hold" do
    it "refuses a purchase with no toppings" do
      pizza = Pizza.create_pizza(name: "Bare", price_cents: 900)

      expect { pizza.purchase(customer_name: "Chris") }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /at least one topping/)
    end

    it "enforces the value object invariant" do
      pizza = Pizza.create_pizza(name: "Margherita", price_cents: 1200)

      expect { pizza.add_topping(name: "Air", amount: 0) }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /amount must be positive/)
    end
  end

  # The how-verb method_missing is live only while a hecksagon is being read.
  # Everywhere else a typo must fail the way Ruby should.
  it "raises NoMethodError for an unknown method outside a hecksagon" do
    expect { Pizza.persisted_by("Memory") }.to raise_error(NoMethodError)
    expect { Pizza.create_pizza(name: "X", price_cents: 1).nonsense }.to raise_error(NoMethodError)
  end
end
