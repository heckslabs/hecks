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

  it "refuses the gate, and stays standing, when the gate's command aborts on its ledger" do
    allow(Hecks::QualityControlCli::QaMainGate).to receive(:call).and_raise(SystemExit.new(1, "the ledger did not boot"))
    adapter = Hecks::Adapters::MainMaintenance.new(root: Dir.pwd)
    expect { adapter.gate(run: "gate-run", sha: sha) }
      .to raise_error(Hecks::Adapters::MainMaintenance::Refused, /the ledger did not boot/)
  end

  it "refuses the real gate on the checkout while a spec runs" do
    allow(Hecks::QualityControlCli::QaMainGate).to receive(:call).and_call_original
    expect { Hecks::QualityControlCli::QaMainGate.call([], root: InMemoryDomain::ROOT) }
      .to raise_error(LiveGateGuard::Violation, /the quick gate on main/)
  end

  it "refuses a started run at the gate when nothing stands in for it, and stays standing" do
    allow(Hecks::QualityControlCli::QaMainGate).to receive(:call).and_call_original
    expect(start_run).to include("GateRefused")
  end

  it "refuses no ask for an undeclared fact" do
    expect(start_run).not_to include("neither receiver identity nor declared command facts")
  end
end
