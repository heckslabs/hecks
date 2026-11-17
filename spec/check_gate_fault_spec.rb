require "spec_helper"
require "hecks/hecks/adapters/codebase/gate"

# What the specs of a refused gate run read: the faults the run's events record.
module GateFaultHelpers
  # Refuses the gate with the error, and dispatches a run of it.
  def refuse_gate(run, error)
    allow(Hecks::Adapters::Codebase::Gate).to receive(:call).and_raise(error)
    @hecks.dispatch_flat("Hecks::GateRun.Gate", run: run, stage: "quick")
  end

  # @param text [String] what the refusal ends with
  # @return [Hash, nil] the payload of the GateFaulted event whose refusal ends with the text
  def fault_ending(text)
    faults = @hecks.registry.event_log.select { |event| event.name == "GateFaulted" }
    faults.map { |event| Hecks::Runtime::Value.materialize(event.payload) }
          .find { |payload| payload[:refusal][:value].end_with?(text) }
  end
end

# A refused gate is recorded as a fault whether or not the refusal names a kind.
RSpec.describe "a refused gate run, recorded as a fault" do
  include GateFaultHelpers

  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  it "records the fault of a refusal that names no kind, with no cause", :aggregate_failures do
    refuse_gate("fault-plain", Hecks::Adapters::ConsoleCapture::Failure.new("gate could not start"))

    expect(fault_ending("gate could not start")).not_to be_nil
    expect(fault_ending("gate could not start")[:cause]).to be_nil
  end

  it "records the fault of a red gate with its cause" do
    gate = Hecks::Adapters::Codebase::Gate
    refuse_gate("fault-red", gate::Red.new("[gate quick] red: rubocop", "gate-quick-rubocop"))

    expect(fault_ending("red: rubocop")[:cause]).to eq(value: "gate-quick-rubocop")
  end
end
