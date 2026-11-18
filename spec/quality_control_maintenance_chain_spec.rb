require "spec_helper"
require_relative "../lib/hecks/quality_control/adapters/main_maintenance"

# A started run reaches the `MainMaintenance` gate with the sha its ask declares.
# QualityControl boots in Memory and the quick gate is stubbed, so nothing runs for real.
RSpec.describe "the QualityControl maintenance chain" do
  let(:qc) { boot_hecks_in_memory }
  let(:sha) { "b" * 40 }

  before { allow(Hecks::QualityControlCli::QaMainGate).to receive(:call).and_return(0) }

  def start_run
    Hecks::Adapters::Driving::CliRunner.call(
      runtime: qc, program: "hecks",
      argv: ["quality_control", "Maintenance.start!", "run.value=gate-run", "sha.value=#{sha}", "--wait"]
    ).first
  end

  it "runs the gate for a started run" do
    start_run
    expect(Hecks::QualityControlCli::QaMainGate).to have_received(:call)
  end

  it "answers the gate's verdict" do
    expect(start_run).to include("GateVerdict")
  end

  it "refuses no ask for an undeclared fact" do
    expect(start_run).not_to include("neither receiver identity nor declared command facts")
  end
end
