require "hecksagain"
require "tmpdir"
require "fileutils"

RSpec.describe "a constructed aggregate" do
  before { boot_in_memory }


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
      pizza = Pizza.create_pizza(name: { value: "Margherita" }, price_cents: { cents: 1200 })

      expect(pizza).to be_a(Pizza)
      expect(pizza.name.to_h).to eq(value: "Margherita")
      expect(pizza.price_cents.to_h).to eq(cents: 1200)
      expect(pizza.status).to eq("available")
      expect(pizza.toppings).to eq([])
    end
  end

  describe "a command that references its aggregate" do
    it "is an instance method that never asks for an id" do
      pizza = Pizza.create_pizza(name: { value: "Margherita" }, price_cents: { cents: 1200 })
      pizza.add_topping(topping: { value: "Basil" }, amount: { value: 3 })

      expect(pizza.toppings.map(&:to_h)).to eq([{ name: "Basil", amount: 3 }])
    end

    it "returns self, so commands chain" do
      pizza = Pizza.create_pizza(name: { value: "Margherita" }, price_cents: { cents: 1200 })
              .add_topping(topping: { value: "Basil" }, amount: { value: 3 })
              .add_topping(topping: { value: "Olive" }, amount: { value: 2 })
              .purchase(customer_name: { value: "Chris" })

      expect(pizza.status).to eq("sold")
      expect(pizza.customer_name.to_h).to eq(value: "Chris")
      expect(pizza.toppings.size).to eq(2)
    end
  end

  describe "reading" do
    it "finds, lists, and counts through the bound adapter" do
      pizza = Pizza.create_pizza(name: { value: "Margherita" }, price_cents: { cents: 1200 })

      expect(Pizza.count).to eq(1)
      expect(Pizza.find(pizza.id).name.to_h).to eq(value: "Margherita")
      expect(Pizza.all.map(&:id)).to eq([pizza.id])
      expect(Pizza.find("nope")).to be_nil
    end

    it "reports the events one instance announced" do
      pizza = Pizza.create_pizza(name: { value: "Margherita" }, price_cents: { cents: 1200 })
              .add_topping(topping: { value: "Basil" }, amount: { value: 3 })
              .purchase(customer_name: { value: "Chris" })

      expect(pizza.events.map(&:name)).to eq(%w[PizzaCreated ToppingAdded PizzaPurchased])
      expect(pizza.events.last.name).to eq("PizzaPurchased")
    end
  end

  describe "the rules still hold" do
    it "refuses a purchase with no toppings" do
      pizza = Pizza.create_pizza(name: { value: "Bare" }, price_cents: { cents: 900 })

      expect { pizza.purchase(customer_name: { value: "Chris" }) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /at least one topping/)
    end

    it "enforces the value object invariant" do
      pizza = Pizza.create_pizza(name: { value: "Margherita" }, price_cents: { cents: 1200 })

      expect { pizza.add_topping(topping: { value: "Air" }, amount: { value: 0 }) }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /ToppingAmount .* an amount is positive/)
    end
  end

  it "raises NoMethodError for an unknown method outside a hecksagon" do
    expect { Pizza.persisted_by("Memory") }.to raise_error(NoMethodError)
    expect { Pizza.create_pizza(name: { value: "X" }, price_cents: { cents: 1 }).nonsense }.to raise_error(NoMethodError)
  end
end
