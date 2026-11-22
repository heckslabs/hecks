require "spec_helper"
require "hecks/hecks/adapters/turn_facts"

# A submission declares what it carries: the Work item, the run, the role, what it reaches, what it
# reverts and the spec that covers it. `WorkSubmitted` hands the manifest on, whether the submitter
# was measured or could not be.
RSpec.describe "a submission that declares what it carries" do
  let(:hecks) { boot_hecks_in_memory }
  let(:port) { instance_double(Hecks::Adapters::TurnFacts) }
  let(:manifest) do
    ["work.value=w-man", "run.value=run-7", "role.value=coder", "reaches.value=lib/a.rb|docs/a.md",
     "revert_of.value=abc0001", "covers.value=spec/a_spec.rb"]
  end

  before { allow(Hecks::Adapters::TurnFacts).to receive(:new).and_return(port) }

  def submit(*extra)
    argv = ["coder", "Submission.submit!", "branch.value=w-man", "sha.value=abc1234", "checkout.value=/tmp/w-man",
            "clean.value=true", *extra, "--wait"]
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, argv: argv, program: "hecks")
  end

  def handed_in = hecks.registry.event_log.reverse.find { |event| event.name == "WorkSubmitted" }.payload.to_s

  it "hands the manifest on in WorkSubmitted once the submitter is measured" do
    allow(port).to receive(:measure_submitter)
      .and_return(inbox: false, resuming: false, first_paths: "docs/a.md", first_spec: "none")
    submit(*manifest)
    expect(handed_in).to include("run-7", "lib/a.rb|docs/a.md", "abc0001", "spec/a_spec.rb")
  end

  it "hands the manifest on in WorkSubmitted when the submitter cannot be measured" do
    allow(port).to receive(:measure_submitter).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "no run")
    submit(*manifest)
    expect(handed_in).to include("w-man", "run-7", "coder")
  end

  it "hands in a submission that names no manifest, its fields empty" do
    allow(port).to receive(:measure_submitter).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "no run")
    submit
    expect(handed_in).to include("w-man")
  end
end
