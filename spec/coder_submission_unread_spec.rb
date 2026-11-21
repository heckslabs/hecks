require "spec_helper"
require "hecks/hecks/adapters/turn_facts"

# A coder does not land past a message it has not read. `Submission.Submit` asks the TurnFacts port,
# here a stand-in, whether an answer to the coder its branch is named for is unread; the branch is
# handed in (`WorkSubmitted`, which starts its landing) only when none is.
RSpec.describe "a submission while an answer to the coder is unread" do
  let(:hecks) { boot_hecks_in_memory }
  let(:port) { instance_double(Hecks::Adapters::TurnFacts) }

  before { allow(Hecks::Adapters::TurnFacts).to receive(:new).and_return(port) }

  def measuring(**facts)
    first = { first_paths: "spec/a_spec.rb", first_spec: "failed", first_example: "a fails" }
    allow(port).to receive(:measure_submitter).and_return({ inbox: false, resuming: false }.merge(first).merge(facts))
  end

  def submit(branch = "w-unread")
    argv = ["coder", "Submission.submit!", "branch.value=#{branch}", "sha.value=abc1234", "checkout.value=/tmp/#{branch}",
            "clean.value=true", "--wait"]
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, argv: argv, program: "hecks")
  end

  def events(...) = JSON.parse(submit(...).first).fetch("events")

  it "withholds a branch whose coder has an answer waiting in its inbox", :aggregate_failures do
    measuring(inbox: true)
    _text, status, why = submit

    expect(status).to eq(1)
    expect(why).to include('failure state "withheld"')
  end

  it "hands nothing to the landing while an answer is on its way" do
    measuring(resuming: true)
    expect(submit.to_s).not_to include("WorkSubmitted")
  end

  it "hands in a branch whose coder has read every answer" do
    measuring
    expect(events).to include("WorkSubmitted")
  end

  it "hands in the same branch again, as after a review of changes" do
    measuring
    submit
    expect(events).to include("WorkSubmitted")
  end

  it "hands in a branch withheld once its answer is read" do
    measuring(inbox: true)
    submit
    measuring
    expect(events).to include("WorkSubmitted")
  end

  it "hands in a branch no started coder run serves" do
    allow(port).to receive(:measure_submitter).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "no started coder run")
    expect(events).to include("WorkSubmitted")
  end
end
