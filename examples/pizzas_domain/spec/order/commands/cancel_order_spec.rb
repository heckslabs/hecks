require_relative "../../spec_helper"

RSpec.describe PizzasDomain::Order::Commands::CancelOrder do
  describe "attributes" do
    subject(:command) { described_class.new(order: "ref-id-123") }

    it "has order" do
      expect(command.order).to eq("ref-id-123")
    end

  end

  describe "event" do
    it "emits CanceledOrder" do
      expect(described_class.event_name).to eq("CanceledOrder")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits CanceledOrder" do
      agg = Order.place(
          customer_name: "example",
          pizza: "example",
          quantity: 1
        )
      Order.cancel(order: "ref-id-123")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("CanceledOrder")
    end
  end
end
