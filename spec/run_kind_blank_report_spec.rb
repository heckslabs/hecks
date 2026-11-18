require "spec_helper"
require "securerandom"

# How the specs of a blank run answer drive one: a KernelRun whose ports are stand-ins, so
# nothing outside the scratch boot is reached.
module BlankRunAnswerHelpers
  # A stand-in whose examine lets the run through and whose perform answers the block's answer.
  def port(answer)
    Object.new.tap do |stand_in|
      stand_in.define_singleton_method(:examine) { |**| { checkout: { value: true } } }
      stand_in.define_singleton_method(:perform) { |**| answer.call }
    end
  end

  # @return [Array<String>] the names of the events a measure answered by the block recorded
  def measured(answer)
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { port(answer) }) do
      Hecks::Runtime::Dispatcher.new(@hecks.registry)
                                .dispatch_flat("Hecks::KernelRun.MeasureKernelCoverage", run: SecureRandom.uuid)
    end
    @hecks.registry.event_log.map(&:name)
  end

  # @return [String, nil] the refusal the run's fault recorded
  def fault_refusal
    fault = @hecks.registry.event_log.find { |event| event.name == "KernelFaulted" }
    fault && Hecks::Runtime::Value.materialize(fault.payload).dig(:refusal, :value)
  end
end

# A run of the Run kind ends saying what happened: its Report type holds a presence rule, and an
# answer or a refusal that says nothing ends the run faulted with a reason, not open and silent.
RSpec.describe "a Run kind run that is answered with nothing" do
  include BlankRunAnswerHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  before { @hecks.registry.event_log.clear }

  it "completes a run that reports something" do
    expect(measured(-> { { report: { value: "every capability has its file" } } })).to include("KernelCompleted")
  end

  it "ends a run that answers a blank report faulted, saying so", :aggregate_failures do
    expect(measured(-> { { report: { value: "  " } } })).not_to include("KernelCompleted")
    expect(fault_refusal).to eq("Kernel answered with no report: it said nothing about what it did")
  end

  it "has the source tree refuse by name a family answer with no report" do
    performing = Object.new.extend(Hecks::Adapters::Performing)
    expect { performing.reported("measure", {}) }.to raise_error(/measure answered with no report/)
  end

  it "ends a run refused with no reason faulted, saying no reason was given" do
    measured(-> { raise Hecks::Adapters::ConsoleCapture::Failure, " " })
    expect(fault_refusal).to match(/\S/)
  end
end
