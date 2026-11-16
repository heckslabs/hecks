require "spec_helper"

# Each policy delivery is timed with the interpreter's clock; the timings sit beside the reaction
# log, so a reaction record keeps the shape the Rust kernel writes.
RSpec.describe Hecks::Runtime::PolicyInterpreter::Timing do
  let(:event) do
    Hecks::Runtime::Event.new(
      name: "Rang", aggregate: "Reflex::Echo", id: "bell-1",
      payload: {}, occurred_at: Time.now.utc.iso8601
    )
  end

  let(:policies) do
    %w[Quick Slow].map do |name|
      Hecks::Bluebook::Policy.new(name: name, on_event: "Rang", trigger_command: "Echo.Ring")
    end
  end

  let(:registry) { registry_for(policies) }

  def registry_for(policies)
    bluebook = Struct.new(:name, :policies) { def aggregate(_name) = nil }.new("Reflex", policies)
    Class.new do
      attr_reader :reaction_log

      define_method(:initialize) { @reaction_log = [] }
      define_method(:log_reaction) { |record, **| @reaction_log << record }
      define_method(:bluebooks) { { "Reflex" => bluebook } }
    end.new
  end

  # Answers each call the next reading: a policy takes the gap between two readings.
  def clock_reading(*seconds) = -> { seconds.shift }

  def refusing_dispatcher
    Class.new do
      define_method(:reaction_depth_reached?) { false }
      define_method(:max_reaction_depth) { 8 }
      define_method(:reenter) { |*, **| raise Hecks::Runtime::GivenNotMet, "no" }
    end.new
  end

  def interpreter(clock)
    Hecks::Runtime::PolicyInterpreter.new(registry, dispatcher: refusing_dispatcher, clock: clock)
  end

  def timed_run
    subject = interpreter(clock_reading(0.0, 0.01, 1.0, 1.25))
    subject.react(event, "Reflex")
    subject.drain_timings
  end

  it "times each policy a reaction runs, refused or not", :aggregate_failures do
    expect(timed_run).to eq([{ policy: "Quick", ms: 10.0 }, { policy: "Slow", ms: 250.0 }])
  end

  it "names the slowest policy" do
    expect(described_class.slowest(timed_run)).to eq(policy: "Slow", ms: 250.0)
  end

  it "names nothing when nothing was timed" do
    expect(described_class.slowest([])).to be_nil
  end

  it "forgets the timings once they are drained", :aggregate_failures do
    subject = interpreter(clock_reading(0.0, 0.01, 1.0, 1.25))
    subject.react(event, "Reflex")
    subject.drain_timings
    expect(subject.drain_timings).to eq([])
  end

  it "leaves the reaction record without a time", :aggregate_failures do
    interpreter(clock_reading(0.0, 0.01, 1.0, 1.25)).react(event, "Reflex")
    expect(registry.reaction_log.map(&:keys).uniq).to eq([%i[policy on trigger delivered reason]])
  end
end
