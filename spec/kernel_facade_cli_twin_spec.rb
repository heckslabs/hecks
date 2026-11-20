require "hecks"
require "hecks/rust_build/kernel_engine"
require_relative "support/driving_twin"

# The Ruby facade and the CLI runner over both engines, on pizzas: the same answers through the
# in-process dispatcher and the kernel dispatcher, and a query the kernel cannot take yet refused
# by name.
RSpec.describe "the Ruby facade and the CLI runner on the kernel engine", :io do
  include DrivingTwin

  it "creates, runs a verb, finds, lists and counts through the facade the same on both engines" do
    ruby, kernel = twin { facade_answers }
    expect(kernel).to eq(ruby).and(satisfy { |answers| answers[:count] == 1 })
  end

  it "answers a CLI command the same through both engines" do
    ruby, kernel = twin { |d| cli(d, *DrivingTwin::CREATE_ARGV) }
    expect(kernel).to eq(ruby)
  end

  it "refuses a CLI query on the kernel engine by name" do
    expect { driven(:kernel) { |d| cli(d, "order.available") } }
      .to raise_error(Hecks::Runtime::KernelDispatcher::NotAnswered, /query step/)
  end
end
