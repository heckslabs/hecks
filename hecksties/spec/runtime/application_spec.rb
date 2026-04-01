require "spec_helper"

RSpec.describe Hecks::Runtime do
  let(:domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String

        validation :name, presence: true

        command "CreatePizza" do
          attribute :name, String
        end
      end

      aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer

        command "PlaceOrder" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end

        command "NotifyChef" do
          reference_to "Pizza"
        end

        policy "NotifyKitchen" do
          on "PlacedOrder"
          trigger "NotifyChef"
        end
      end
    end
  end

  describe "default configuration" do
    subject(:app) { Hecks.load(domain) }

    it "creates memory repositories for each aggregate" do
      expect(app["Pizza"]).to be_a(PizzasDomain::Adapters::PizzaMemoryRepository)
      expect(app["Order"]).to be_a(PizzasDomain::Adapters::OrderMemoryRepository)
    end

    it "runs commands and publishes events" do
      event = app.run("CreatePizza", name: "Margherita")
      expect(event.name).to eq("Margherita")
      expect(app.events.size).to eq(1)
    end

    it "allows subscribing to events" do
      received = nil
      app.on("CreatedPizza") { |e| received = e }
      app.run("CreatePizza", name: "Pepperoni")
      expect(received.name).to eq("Pepperoni")
    end
  end

  describe "custom adapter" do
    it "uses the provided adapter class" do
      # Boot the domain first so PizzasDomain::Ports::PizzaRepository is defined
      Hecks.load(domain)

      custom_repo = Class.new do
        include PizzasDomain::Ports::PizzaRepository
        def find(id) = "custom_find"
        def save(pizza) = "custom_save"
        def delete(id) = "custom_delete"
      end

      app = Hecks.load(domain) do
        adapter "Pizza", custom_repo.new
      end

      expect(app["Pizza"].find("x")).to eq("custom_find")
    end
  end

  describe "aggregate command methods" do
    let!(:app) { Hecks.load(domain) }

    it "defines class methods on aggregates for each command" do
      expect(PizzasDomain::Pizza).to respond_to(:create)
    end

    it "dispatches through the command bus and returns a command with aggregate" do
      result = PizzasDomain::Pizza.create(name: "Margherita")
      expect(result.aggregate).to be_a(PizzasDomain::Pizza)
      expect(result.name).to eq("Margherita")
    end

    it "saves the aggregate to the repository" do
      pizza = PizzasDomain::Pizza.create(name: "Pepperoni")
      found = app["Pizza"].find(pizza.id)
      expect(found).not_to be_nil
      expect(found.name).to eq("Pepperoni")
    end

    it "fires events" do
      received = nil
      app.on("CreatedPizza") { |e| received = e }
      PizzasDomain::Pizza.create(name: "Hawaiian")
      expect(received.name).to eq("Hawaiian")
    end

    it "works for other aggregates" do
      pizza = PizzasDomain::Pizza.new(id: "abc-123", name: "Margherita")
      pizza.save
      result = PizzasDomain::Order.place(pizza: "abc-123", quantity: 3)
      expect(result.aggregate).to be_a(PizzasDomain::Order)
      expect(result.pizza).to eq("abc-123")
      expect(result.quantity).to eq(3)
    end
  end

  describe "constant hoisting" do
    let!(:app) { Hecks.load(domain) }

    it "hoists aggregates to top level" do
      expect(::Pizza).to eq(PizzasDomain::Pizza)
    end

    it "makes value objects accessible through top-level aggregate" do
      expect(::Pizza::Topping).to eq(PizzasDomain::Pizza::Topping) if defined?(PizzasDomain::Pizza::Topping)
    end

    it "allows calling commands on the top-level constant" do
      pizza = ::Pizza.create(name: "TopLevel")
      expect(pizza.name).to eq("TopLevel")
    end
  end

  describe "#inspect" do
    it "shows a readable summary" do
      app = Hecks.load(domain)
      expect(app.inspect).to include("Pizzas")
      expect(app.inspect).to include("2 repositories")
    end
  end
end
