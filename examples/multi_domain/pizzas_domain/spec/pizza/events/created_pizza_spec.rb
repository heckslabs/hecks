require_relative "../../spec_helper"

RSpec.describe PizzasDomain::Pizza::Events::CreatedPizza do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          name: "example",
          style: "example",
          price: 1.0
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

  it "carries name" do
    expect(event.name).to eq("example")
  end

  it "carries style" do
    expect(event.style).to eq("example")
  end

  it "carries price" do
    expect(event.price).to eq(1.0)
  end
end
