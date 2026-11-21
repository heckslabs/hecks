require "spec_helper"
require "hecks/hecks/adapters/turn_facts"

# A branch starts with a spec that fails on main. `Submission.Submit` asks the TurnFacts port, here
# a stand-in, what the branch's first commit is; the policies on `SubmitterMeasured` hand the branch
# in only when that commit adds a spec that fails on main, or changes nothing but docs or ledgers.
RSpec.describe "a submission whose first commit is judged for being test-first" do
  let(:hecks) { boot_hecks_in_memory }
  let(:port) { instance_double(Hecks::Adapters::TurnFacts) }

  before { allow(Hecks::Adapters::TurnFacts).to receive(:new).and_return(port) }

  def measuring(**facts)
    base = { inbox: false, resuming: false, first_paths: "spec/a_spec.rb", first_spec: "failed", first_example: "a fails" }
    allow(port).to receive(:measure_submitter).and_return(base.merge(facts))
  end

  def submit
    argv = ["coder", "Submission.submit!", "branch.value=w-first", "sha.value=abc1234", "checkout.value=/tmp/w-first",
            "clean.value=true", "--wait"]
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, argv: argv, program: "hecks")
  end

  def refusal
    submit
    hecks.registry.event_log.reverse.find { |event| event.name == "SubmissionWithheld" }.payload.to_s
  end

  def accepted? = JSON.parse(submit.first).fetch("events").include?("WorkSubmitted")

  it "hands in a branch whose first spec fails on main" do
    measuring
    expect(accepted?).to be(true)
  end

  it "withholds a branch whose first commit adds no spec, naming why" do
    measuring(first_spec: "none", first_paths: "lib/a.rb")
    expect(refusal).to include("adds no spec or .behaviors file")
  end

  it "withholds a branch whose first spec passes on main, naming why" do
    measuring(first_spec: "passed")
    expect(refusal).to include("passes on main")
  end

  it "hands in a branch whose first commit changes only docs" do
    measuring(first_spec: "none", first_paths: "docs/a.md|README.md")
    expect(accepted?).to be(true)
  end

  it "withholds a branch whose first commit mixes docs with code and no spec" do
    measuring(first_spec: "none", first_paths: "docs/a.md|lib/a.rb")
    expect(submit[1]).to eq(1)
  end

  it "hands in a branch whose first spec did not load or could not be run" do
    measuring(first_spec: "errored")
    expect(accepted?).to be(true)
  end

  it "withholds for an unread answer first, even with no spec" do
    measuring(inbox: true, first_spec: "none", first_paths: "lib/a.rb")
    expect(refusal).to include("unread")
  end

  it "hands in a branch whose first commit could not be measured" do
    allow(port).to receive(:measure_submitter).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "no started coder run")
    expect(accepted?).to be(true)
  end
end
