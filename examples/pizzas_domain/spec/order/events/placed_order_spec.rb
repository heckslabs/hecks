require_relative "../../spec_helper"

RSpec.describe PizzasDomain::Order::Events::PlacedOrder do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          customer_name: "example",
          pizza: "example",
          quantity: 1,
          items: [],
          status: "example"
        ) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries aggregate_id" do
    expect(event.aggregate_id).to eq("example")
  end

  it "carries customer_name" do
    expect(event.customer_name).to eq("example")
  end

  it "carries pizza" do
    expect(event.pizza).to eq("example")
  end

  it "carries quantity" do
    expect(event.quantity).to eq(1)
  end

  it "carries items" do
    expect(event.items).to eq([])
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
