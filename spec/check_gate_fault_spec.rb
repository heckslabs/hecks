require "spec_helper"
require "hecks/hecks/adapters/codebase/gate"

# What the specs of a refused gate run read: the faults the run's events record.
module GateFaultHelpers
  # Refuses the gate with the error, and dispatches a run of it.
  def refuse_gate(run, error)
    allow(Hecks::Adapters::Codebase::Gate).to receive(:call).and_raise(error)
    @hecks.dispatch_flat("Hecks::GateRun.Gate", run: run, stage: "quick")
  end

  # @return [Hash, nil] the payload of the run's GateFaulted event
  def fault_of(run)
    faults = @hecks.registry.event_log.select { |event| event.name == "GateFaulted" }
    faults.map { |event| Hecks::Runtime::Value.materialize(event.payload) }.find { |payload| payload[:run] == run }
  end
end

# A refused gate is recorded as a fault whether or not the refusal names a kind.
RSpec.describe "a refused gate run, recorded as a fault" do
  include GateFaultHelpers

  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  it "records the fault of a refusal that names no kind", :aggregate_failures do
    refuse_gate("fault-plain", Hecks::Adapters::ConsoleCapture::Failure.new("gate could not start"))

    expect(fault_of("fault-plain")[:refusal]).to end_with("gate could not start")
    expect(fault_of("fault-plain")[:cause]).to be_nil
  end

  it "records the fault of a red gate with its cause" do
    gate = Hecks::Adapters::Codebase::Gate
    refuse_gate("fault-red", gate::Red.new("[gate quick] red: rubocop", "gate-quick-rubocop"))

    expect(fault_of("fault-red")[:cause]).to eq("gate-quick-rubocop")
  end
end
