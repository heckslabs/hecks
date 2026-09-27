require "hecks"

# Pins that `record_event` is a real method on the wrapper: Emission guards on
# `repository.respond_to?(:record_event)`, so an undefined method silently drops durable events.
# Adapter specs call `adapter.record_event` directly and cannot catch this.
RSpec.describe Hecks::Ports::Persistence::AppendOnly do
  include InMemoryDomain

  let(:runtime) { boot_in_memory }

  it "record_event is a real, callable method — not silently undefined" do
    expect(described_class.method_defined?(:record_event)).to be(true)
  end

  it "forwards record_event to an adapter that implements it" do
    runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                          name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })

    repository = runtime.registry.repository("Pizzas", runtime.registry.bluebooks["Pizzas"].aggregates.first)

    expect(repository.events.map(&:name)).to include("PizzaCreated")
  end

  it "record_event no-ops rather than raising for an adapter that does not implement it" do
    adapter = double(append: nil, project: nil, entries: [])
    repository = described_class.new(adapter)

    expect { repository.record_event(:whatever) }.not_to raise_error
  end
end
