require_relative "../../spec_helper"

RSpec.describe PizzasDomain::Order::Commands::PlaceOrder do
  describe "attributes" do
    subject(:command) { described_class.new(quantity: 1) }

    it "has quantity" do
      expect(command.quantity).to eq(1)
    end

  end

  describe "event" do
    it "emits PlacedOrder" do
      expect(described_class.event_name).to eq("PlacedOrder")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Order.place(quantity: 1)
      expect(result).not_to be_nil
      expect(Order.find(result.id)).not_to be_nil
    end

    it "emits PlacedOrder to the event log" do
      Order.place(quantity: 1)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("PlacedOrder")
    end
  end
end
