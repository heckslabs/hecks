require "hecks"
require "hecks/rust_build/kernel_client"
require "hecks/runtime/kernel_dispatcher"

# The records the kernel dispatcher reads back from the kernel's store against a stand-in client,
# hydrated against pizzas' described Order as the in-process repository hydrates them.
RSpec.describe Hecks::Runtime::KernelDispatcher::Repository do
  let(:client) { instance_double(Hecks::RustBuild::KernelClient) }
  let(:registry) { Hecks.describe(File.expand_path("../../examples/pizzas", __dir__)).registry }
  let(:order) { registry.bluebook("Pizzas").aggregates.find { |aggregate| aggregate.name == "Order" } }
  let(:held) { { "Pizzas::Order#p-1" => { "name" => { "value" => "a" }, "toppings" => [] }, "Pizzas::Other#o" => {} } }
  let(:repository) { described_class.new(client, "Pizzas", order) }

  before { allow(client).to receive(:call).with("instances" => true).and_return("ok" => true, "instances" => held) }

  it "reads a record back as a hydrated instance", :aggregate_failures do
    expect(repository.find("p-1")).to be_a(Hecks::Runtime::Instance)
    expect(repository.find("p-1").to_h).to include(id: "p-1", toppings: [])
  end

  it "finds nothing the kernel does not hold" do
    expect(repository.find("x")).to be_nil
  end

  it "lists and counts only the aggregate's own records", :aggregate_failures do
    expect(repository.all.map(&:id)).to eq(["p-1"])
    expect(repository.count).to eq(1)
  end

  it "is read for a dispatch's state only when the state is asked for", :aggregate_failures do
    event = { "name" => "PizzaCreated", "aggregate" => "Pizzas::Order", "id" => "p-1" }
    allow(client).to receive(:dispatch).and_return("ok" => true, "events" => [event])
    result = Hecks::Runtime::KernelDispatcher.new(client, registry: registry).dispatch_flat("Pizzas::Order.CreatePizza")
    expect(client).not_to have_received(:call)
    expect(result.state).to include(id: "p-1")
  end
end
