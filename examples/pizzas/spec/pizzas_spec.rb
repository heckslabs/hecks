# Pizzas Domain Spec
#
# Integration tests for the Pizzas example domain.
# Exercises boot, commands, events, queries, invariants,
# lifecycle transitions, value objects, actor system, and projections.
#
#   rspec examples/pizzas/spec/pizzas_spec.rb

require_relative "spec_helper"

RSpec.describe "Pizzas Domain" do
  let!(:runtime) { Hecks.boot(File.expand_path("..", __dir__)) }

  after { runtime.actor_system.stop }

  # -- Boot ---------------------------------------------------------------

  describe "boot" do
    it "loads the domain and returns a runtime" do
      expect(runtime).to be_a(Hecks::Runtime)
      expect(runtime.domain.name).to eq("Pizzas")
    end
  end

  # -- Aggregates ---------------------------------------------------------

  describe "aggregates" do
    it "defines Pizza and Order aggregates" do
      names = runtime.domain.aggregates.map(&:name)
      expect(names).to include("Pizza", "Order")
    end
  end

  # -- Commands -----------------------------------------------------------

  describe "CreatePizza" do
    it "persists a pizza to the repo" do
      Pizza.create(name: "Margherita", description: "Classic")
      expect(Pizza.count).to eq(1)
      expect(Pizza.all.first.name).to eq("Margherita")
    end
  end

  describe "PlaceOrder" do
    it "persists an order to the repo" do
      Order.place(customer_name: "Alice", quantity: 1)
      expect(Order.count).to eq(1)
      expect(Order.all.first.customer_name).to eq("Alice")
    end
  end

  # -- Events -------------------------------------------------------------

  describe "events" do
    it "emits CreatedPizza on create" do
      Pizza.create(name: "Pepperoni", description: "Spicy")
      event_names = runtime.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("CreatedPizza")
    end

    it "emits CanceledOrder on cancel" do
      order = Order.place(customer_name: "Bob", quantity: 1)
      Order.cancel(order: order.id)
      event_names = runtime.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("CanceledOrder")
    end
  end

  # -- Invariants ---------------------------------------------------------

  describe "invariants" do
    it "raises InvariantError when Topping amount is 0" do
      expect {
        PizzasBluebook::Pizza::Topping.new(name: "Bad", amount: 0)
      }.to raise_error(PizzasBluebook::InvariantError, /amount must be positive/)
    end
  end

  # -- Lifecycle transitions ----------------------------------------------

  describe "CancelOrder" do
    it "transitions status from pending to cancelled" do
      order = Order.place(customer_name: "Carol", quantity: 1)
      expect(order.status).to eq("pending")

      Order.cancel(order: order.id)
      found = Order.find(order.id)
      expect(found.status).to eq("cancelled")
    end
  end

  # -- Value objects -------------------------------------------------------

  describe "Topping value object" do
    it "is frozen and exposes name and amount" do
      topping = PizzasBluebook::Pizza::Topping.new(name: "Basil", amount: 2)
      expect(topping).to be_frozen
      expect(topping.name).to eq("Basil")
      expect(topping.amount).to eq(2)
    end
  end

  # -- Queries ------------------------------------------------------------

  describe "queries" do
    it "ByDescription returns matching pizzas" do
      Pizza.create(name: "Hawaiian", description: "Tropical")
      Pizza.create(name: "Veggie", description: "Garden")

      results = Pizza.by_description("Tropical")
      expect(results.map(&:name)).to eq(["Hawaiian"])
    end

    it "Pending returns only pending orders" do
      Order.place(customer_name: "Dave", quantity: 1)
      order2 = Order.place(customer_name: "Eve", quantity: 1)
      Order.cancel(order: order2.id)

      pending = Order.pending
      expect(pending.map(&:customer_name)).to eq(["Dave"])
    end
  end

  # -- Actor system -------------------------------------------------------

  describe "actor system" do
    it "dispatches commands via ask" do
      ref = runtime.actor_system["Pizza"]
      result = ref.ask("CreatePizza", name: "ActorPizza", description: "Via actor")
      expect(result).to respond_to(:name)
      expect(result.name).to eq("ActorPizza")
    end
  end

  # -- Projections --------------------------------------------------------

  describe "projections" do
    it "auto-projection tracks Pizza records after create" do
      projection = runtime.projection("Pizza")
      expect(projection.all.size).to eq(0)

      Pizza.create(name: "Projected", description: "Test")
      expect(projection.all.size).to eq(1)
    end
  end
end
