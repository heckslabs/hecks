require "hecks"
require "hecks/rust_build/kernel_engine"
require_relative "../packages/hecks-rails/lib/hecks/rails/booted"
require_relative "support/driving_twin"

# The Rails boot under `HECKS_ENGINE=kernel`, on pizzas: its declarations come from the
# described registry, and the door the facade installs dispatches through the kernel.
RSpec.describe Hecks::Rails::Booted, :io do
  include DrivingTwin

  before { with_engine("kernel") }

  after do
    described_class.dispatcher.close if described_class.booted?
    described_class.reset!
  end

  it "answers its declarations from the described registry", :aggregate_failures do
    expect(described_class.boot(DrivingTwin::PIZZAS)).to be_a(Hecks::Runtime::KernelDispatcher)
    expect(described_class.declaration("pizzas").name).to eq("Pizzas")
  end

  it "dispatches through the kernel from the door" do
    described_class.boot(DrivingTwin::PIZZAS)
    created = described_class.door("Pizzas", "Order").create_pizza!(**DrivingTwin::PIZZA)
    expect(created.id).to eq(described_class.dispatcher.events.first.id)
  end
end
