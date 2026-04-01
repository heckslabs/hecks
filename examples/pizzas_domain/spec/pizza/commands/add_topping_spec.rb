require_relative "../../spec_helper"

RSpec.describe PizzasDomain::Pizza::Commands::AddTopping do
  describe "attributes" do
    subject(:command) { described_class.new(
          pizza: "ref-id-123",
          name: "example",
          amount: 1
        ) }

    it "has pizza" do
      expect(command.pizza).to eq("ref-id-123")
    end

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has amount" do
      expect(command.amount).to eq(1)
    end

  end

  describe "event" do
    it "emits AddedTopping" do
      expect(described_class.event_name).to eq("AddedTopping")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits AddedTopping" do
      agg = Pizza.create(name: "example", description: "example")
      Pizza.add_topping(pizza: "ref-id-123", name: "example", amount: 1)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("AddedTopping")
    end
  end
end
