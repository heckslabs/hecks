require "hecks"
require "hecks/rust_build/kernel_engine"
require_relative "support/kernel_twin"

# Under `engine: :kernel` a command that `needs :now` gets its time from the registry's clock
# port, through the kernel's fact callback, as the in-process engine does: a spec that binds a
# fixed clock sees that clock's reading in the events of both engines. The hello carries the
# tables the domain's IR builds, so a declared default fills on the kernel as it does in Ruby.
RSpec.describe Hecks::RustBuild::KernelEngine, :io do
  include KernelTwin

  # A fixed clock, bound in place of the system clock on both engines.
  module KernelNeedsFixedClock
    module_function

    def now = 5_000
  end

  before { stub_const("Hecks::Adapters::SystemClock", KernelNeedsFixedClock) }

  let(:lease_clock) { File.expand_path("../qa/stress_domains/lease_clock", __dir__) }

  def key = { value: "lease-a" }

  def acquire(dispatcher)
    dispatcher.dispatch_flat("LeaseClock::Lease.Register", key: key)
    dispatcher.dispatch_flat("LeaseClock::Lease.Acquire", key: key, holder: { value: "h" }, expiry: { value: 9_000 })
    canonical(dispatcher.events)
  end

  def run_on(engine)
    return on_engine(lease_clock, :ruby) { |dispatcher| acquire(dispatcher) } if engine == :ruby

    on_kernel(lease_clock, described_class.binary_for("lease_clock")) { |dispatcher| acquire(dispatcher) }
  end

  it "answers an omitted now from the bound clock, as the in-process engine does" do
    expect(run_on(:kernel)).to eq(run_on(:ruby))
  end

  it "carries the bound clock's reading into the event" do
    acquired = run_on(:kernel).find { |event| event["name"] == "LeaseAcquired" }
    expect(acquired.to_s).to include("5000")
  end
end
