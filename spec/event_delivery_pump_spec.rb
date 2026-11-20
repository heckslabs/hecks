require "spec_helper"
require "hecks/quality_control/adapters/pump_tools"

# EventDelivery's `Pump.Run` on the QualityControl ledger (ADR 0178): `PumpOnRequest` asks the
# `Pumping` port, which QualityControl binds to `PumpTools`, and the answer is recorded on the run.
# The adapter is stubbed: the real one runs the QA ledger's pump as its own process.
RSpec.describe "EventDelivery pump on the QualityControl ledger" do
  let(:ledger) { Hecks.boot(File.expand_path("../lib/hecks/quality_control", __dir__)) }

  let(:tools) { instance_double(Hecks::Adapters::PumpTools) }

  before { allow(Hecks::Adapters::PumpTools).to receive(:new).and_return(tools) }

  def run_pump(name)
    ledger.dispatch_flat("EventDelivery::Pump.Run", run: name)
    ledger.query("EventDelivery::Pump.All").find { |row| row[:run][:value] == name }
  end

  it "completes a run the adapter answers, with what the pump reported", :aggregate_failures do
    allow(tools).to receive(:carry).and_return(text: "event pump: 0 line(s) reported")
    row = run_pump("run-1")

    expect(row[:status]).to eq("completed")
    expect(row[:report][:value]).to eq("event pump: 0 line(s) reported")
  end

  it "faults a run the adapter refuses, with the reason", :aggregate_failures do
    allow(tools).to receive(:carry).and_raise(Hecks::Adapters::QaTool::ToolRefused, "no ledger")
    row = run_pump("run-2")

    expect(row[:status]).to eq("faulted")
    expect(row[:report][:value]).to include("no ledger")
  end

  it "drops QualityControl's own pump aggregates" do
    names = ledger.registry.bluebook("QualityControl").aggregates.map(&:hecks_name)

    expect(names & %w[EventCursor EventReaction EventPump]).to be_empty
  end
end
