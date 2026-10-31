require "spec_helper"

RSpec.describe Hecks::Adapters::Driving::CliRunner::ResumeWords do
  let(:host)      { Object.new.extend(described_class) }
  let(:process)   { Struct.new(:name, :resumes).new("GateAndBoard", ["gated=GateRun.Gate", "landing=Landing.Land"]) }
  let(:bluebook)  { Struct.new(:name, :process_managers).new("Hecks", [process]) }
  let(:scope)     { { runtime: runtime, bluebook: bluebook, program: "hecks" } }
  let(:runtime)   { Struct.new(:saga_interpreter).new(interpreter) }
  let(:interpreter) { double("interpreter") }

  it "maps a faulted stage to its resume command, as a bang line" do
    expect(host.resume_command(bluebook, "gated")).to eq("GateRun.Gate!")
  end

  it "refuses a stage that declares no resume command" do
    expect(host.resume_stage(scope, { stage: "checking", arguments: {} })[:answer].last)
      .to eq(Hecks::Adapters::Driving::ExitStatus::REFUSED)
  end

  it "answers the usage when no run is named" do
    expect(host.resume_answer(scope, ["resume"])[:answer].last)
      .to eq(Hecks::Adapters::Driving::ExitStatus::USAGE)
  end

  it "refuses a run that is not waiting for a person, with the reason" do
    allow(interpreter).to receive(:resume).and_return({ resumed: false, reason: "saga is landing, not needs_human" })
    expect(host.resume_answer(scope, ["resume", "r1"])[:answer].first).to include("needs_human")
  end

  it "dispatches the faulted stage's command with the saved arguments and never calls land" do
    allow(interpreter).to receive(:resume).and_return({ resumed: true, stage: "gated",
                                                        arguments: { run: "r1", branch: "feature" } })
    expect(Hecks::Adapters::Driving::CliRunner).to receive(:call)
      .with(hash_including(argv: ["GateRun.Gate!", "run=r1", "branch=feature"])).and_return(["ok", 0])
    host.resume_answer(scope, ["resume", "r1"])
  end
end
