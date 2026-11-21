require "spec_helper"
require_relative "../support/nested_reactions"

# A reaction that starts another is timed whole and net of the one it started, so the slowest
# step of a beat is the one that spent the time, not the first one of its cascade. When the
# outermost reaction ends, the cascade's timings go to the thread's settle listener.
RSpec.describe Hecks::Runtime::PolicyInterpreter::Timing do
  include NestedReactions

  let(:heard) { [] }
  let(:interpreter) do
    Hecks::Runtime::PolicyInterpreter.new(settling_registry, dispatcher: nested, clock: clock)
  end
  let(:nested) { reentering { interpreter.react(event_named("Echoed"), "Reflex") } }

  # Outer starts at 0 and ends at 1.0; the inner one it starts runs from 0.1 to 0.9.
  let(:clock) { readings(0.0, 0.1, 0.9, 1.0) }

  def cascade = cascade_of(interpreter, heard)

  it "names the nested step slowest, by the time it spent itself" do
    expect(cascade.first).to include(policy: "Inner", ms: 800.0, self_ms: 800.0, depth: 1)
  end

  it "takes the reactions a step started out of its own time" do
    expect(cascade.last).to include(policy: "Outer", ms: 1000.0, self_ms: 200.0, depth: 0)
  end

  it "reports the cascade once, when the outermost reaction ends" do
    cascade
    expect(heard.size).to eq(1)
  end

  it "records the CPU each step used" do
    expect(cascade).to all(include(cpu_ms: be >= 0.0, self_cpu_ms: be >= 0.0))
  end
end
