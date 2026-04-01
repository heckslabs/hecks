require_relative "../../spec_helper"

RSpec.describe PizzasDomain::Order::Events::PlacedOrder do
  subject(:event) { described_class.new(aggregate_id: "example", quantity: 1) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries aggregate_id" do
    expect(event.aggregate_id).to eq("example")
  end

  it "carries quantity" do
    expect(event.quantity).to eq(1)
  end
end
