require_relative "../spec_helper"

RSpec.describe "Order lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'pending' state" do
    agg = Order.place(
          customer_name: "example",
          pizza: "example",
          quantity: 1
        )
    expect(agg.status).to eq("pending")
  end

  it "CancelOrder transitions to 'cancelled'" do
    agg = Order.place(
          customer_name: "example",
          pizza: "example",
          quantity: 1
        )
    Order.cancel(order: agg.id)
    updated = Order.find(agg.id)
    expect(updated.status).to eq("cancelled")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("CanceledOrder")
  end

  it "generates status predicates" do
    agg = Order.place(
          customer_name: "example",
          pizza: "example",
          quantity: 1
        )
    expect(agg.pending?).to be true
    expect(agg.cancelled?).to be false
  end
end
