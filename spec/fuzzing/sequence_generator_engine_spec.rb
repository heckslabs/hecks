require "spec_helper"
require "hecks/fuzzing/sequence_generator"

# The generator's engine choice, its seeded clock and how it reads a kernel's declines, without a
# kernel binary: a stand-in runtime over the in-process one plays the kernel's answers.
RSpec.describe Hecks::Fuzzing::SequenceGenerator do
  let(:lease_clock) { File.join(InMemoryDomain::ROOT, "qa/stress_domains/lease_clock") }
  let(:drive) { Hecks::Fuzzing::SequenceGenerator::Drive }

  # The in-process runtime, except that each call of `method` raises `error`, as the kernel's does.
  def kernel_like(error, method = :query)
    stand_in = Class.new(SimpleDelegator) { define_method(method) { |*, **| raise error } }
    allow(drive).to receive(:open).and_wrap_original do |original, *args, **opts, &block|
      original.call(*args, **opts) { |runtime| block.call(stand_in.new(runtime)) }
    end
  end

  # Seed 4 malforms an `Expired` query by dropping its `now`, which an engine would read from its
  # own clock.
  def needs_now_steps
    described_class.generate(lease_clock, seed: 4, steps: 40)
                   .select { |step| step.fetch("verb") { step["query"] }.to_s.end_with?("Acquire", "Expired") }
  end

  it "refuses an engine it cannot drive by name" do
    expect { described_class.new(lease_clock, seed: 1, steps: 1, engine: :jvm) }
      .to raise_error(ArgumentError, /engine: must be one of \[:ruby, :kernel\], got :jvm/)
  end

  it "gives every step whose verb needs the clock its now, whatever the adversary dropped" do
    expect(needs_now_steps).to include(anything).and all(include("args" => include("now")))
  end

  it "builds the same steps when every query goes unanswered, as on the kernel" do
    expected = described_class.generate(lease_clock, seed: 4, steps: 25)
    kernel_like(Hecks::Runtime::KernelDispatcher::NotAnswered.new("no query step"))
    expect(described_class.generate(lease_clock, seed: 4, steps: 25)).to eq(expected)
  end

  it "records an unanswered query as the outcome NotAnswered" do
    kernel_like(Hecks::Runtime::KernelDispatcher::NotAnswered.new("no query step"))
    tuples = described_class.trace(lease_clock, seed: 4, steps: 25).coverage.map(&:last)
    expect(tuples.grep(/\| query \|/)).to include(anything).and all(end_with("| NotAnswered"))
  end

  it "lets a protocol failure through rather than read it as a refusal" do
    kernel_like(Hecks::RustBuild::KernelClient::Unreachable.new("kernel closed its output"))
    expect { described_class.trace(lease_clock, seed: 4, steps: 25) }
      .to raise_error(Hecks::RustBuild::KernelClient::Unreachable)
  end

  it "reads a kernel refusal of a command as a declined step" do
    kernel_like(Hecks::Runtime::KernelDispatcher::Refused.new("refused"), :dispatch_flat)
    tuples = described_class.trace(lease_clock, seed: 4, steps: 25).coverage.map(&:last)
    expect(tuples.grep(/\| verb \|/)).to include(anything).and all(end_with("| Refused"))
  end
end
