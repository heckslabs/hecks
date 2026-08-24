require "hecks"
require "tmpdir"
require "fileutils"

RSpec.describe "a constructed aggregate" do
  before { boot_in_memory }

  it "names the domain and its aggregates" do
    expect(Pizzas.aggregates).to eq(["Order"])
    expect(Pizzas.vision).to include("sell it to a customer")
  end

  it "turns commands into snake_case methods" do
    expect(Order.commands).to eq(%w[add_topping! create_pizza! purchase!])
  end

  it "is a door over the runtime, not a minted class" do
    expect(Order).to be_a(Module)
    expect(Order).not_to be_a(Class)
    expect(Order.ir).to be_a(Hecks::Bluebook::Aggregate)
    expect(Order.fqn).to eq("Pizzas::Order")
  end

  describe "a creating command" do
    it "is a module method returning the new record in hand" do
      pizza = Order.create_pizza!(name:  { value: "Margherita" },
                                  pizza: { price_cents: { cents: 1200 },
                                           size:        { value: "large" } })

      expect(pizza).to be_a(Hecks::Facade::Handle)
      expect(pizza.name.to_h).to eq(value: "Margherita")
      expect(pizza.pizza.price_cents.to_h).to eq(cents: 1200)
      expect(pizza.status).to eq("available")
      expect(pizza.toppings).to eq([])
    end
  end

  describe "a command that references its aggregate" do
    it "is an instance method that never asks for an id" do
      pizza = Order.create_pizza!(name:  { value: "Margherita" },
                                  pizza: { price_cents: { cents: 1200 },
                                           size:        { value: "large" } })
      pizza.add_topping!(topping: { value: "Basil" }, amount: { value: 3 })

      expect(pizza.toppings.map(&:to_h)).to eq([{ name: "Basil", amount: 3 }])
    end

    it "returns self, so commands chain" do
      pizza = Order.create_pizza!(name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
                   .add_topping!(topping: { value: "Basil" }, amount: { value: 3 })
                   .add_topping!(topping: { value: "Olive" }, amount: { value: 2 })
                   .purchase!(customer_name: { value: "Chris" }, amount: { cents: 1200 })

      expect(pizza.status).to eq("sold")
      expect(pizza.customer_name.to_h).to eq(value: "Chris")
      expect(pizza.toppings.size).to eq(2)
    end
  end

  describe "reading" do
    it "finds, lists, and counts through the bound adapter" do
      pizza = Order.create_pizza!(name:  { value: "Margherita" },
                                  pizza: { price_cents: { cents: 1200 },
                                           size:        { value: "large" } })

      expect(Order.count).to eq(1)
      expect(Order.find(pizza.id).name.to_h).to eq(value: "Margherita")
      expect(Order.all.map(&:id)).to eq([pizza.id])
      expect(Order.find("nope")).to be_nil
    end

    it "reports the events one instance announced" do
      pizza = Order.create_pizza!(name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
                   .add_topping!(topping: { value: "Basil" }, amount: { value: 3 })
                   .purchase!(customer_name: { value: "Chris" }, amount: { cents: 1200 })

      expect(pizza.events.map(&:name)).to eq(%w[PizzaCreated ToppingAdded PizzaPurchased])
      expect(pizza.events.last.name).to eq("PizzaPurchased")
    end
  end

  describe "the rules still hold" do
    it "refuses a purchase with no toppings" do
      pizza = Order.create_pizza!(name: { value: "Bare" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } })

      expect { pizza.purchase!(customer_name: { value: "Chris" }, amount: { cents: 900 }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /at least one topping/)
    end

    it "enforces the value object invariant" do
      pizza = Order.create_pizza!(name:  { value: "Margherita" },
                                  pizza: { price_cents: { cents: 1200 },
                                           size:        { value: "large" } })

      expect { pizza.add_topping!(topping: { value: "Air" }, amount: { value: 0 }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /ToppingAmount .* an amount is positive/)
    end
  end

  it "raises NoMethodError for an unknown method outside a hecksagon" do
    expect { Order.persisted_by("Memory") }.to raise_error(NoMethodError)
    expect { Order.create_pizza!(name: { value: "X" }, pizza: { price_cents: { cents: 1 }, size: { value: "small" } }).nonsense }
      .to raise_error(NoMethodError)
  end
end
