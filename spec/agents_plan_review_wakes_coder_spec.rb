require "spec_helper"
require_relative "support/stand_in_claude"

# What the spec drives: coder runs waiting on Work items, an architect review of one of them, and a
# fake runner standing in for `claude`'s resume that records which run it was asked to wake.
module WakesCoderHelpers
  def fake_runner(log)
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0 }).tap do |agents|
        allow(agents).to(receive(:resume)) do |**held|
          log << held
          { resumed_at: { value: Time.now.utc.iso8601 }, session: { value: "stand-in-session" } }
        end
      end
    end)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def wait_as_coder(work)
    launch("agent_run.dispatch!", "run.value=#{work}", "repo.value=#{scratch}", "brief.value=build", "agent.value=coder",
           "work.value=#{work}", "--wait")
  end

  def request_review(work)
    launch("agents", "PlanReview.request!", "run.value=r-#{work}", "work.value=#{work}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=plan", "--wait")
  end

  def architect_closes(work, verdict)
    state = { state: "done", detail: "reviewed", output: { result: verdict } }
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
    launch("agent_run.check!", "to=r-#{work}", "--wait")
  end

  def runs_woken = woken.map { |held| held.dig(:run, :value).to_s }
end

# A recorded plan verdict resumes the coder run waiting on that Work item and no other.
RSpec.describe "a recorded plan verdict waking the coder waiting for it" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }

  def review(work, verdict)
    request_review(work)
    architect_closes(work, verdict)
  end

  it "resumes the coder run keyed by the reviewed Work item, with the findings", :aggregate_failures do
    wait_as_coder("w-one")
    review("w-one", "Verdict: sound. Build it.")
    expect(runs_woken).to eq(["w-one"])
    expect(woken.first[:answer].to_s).to include("Build it.")
  end

  it "wakes no coder waiting on a different Work item" do
    wait_as_coder("w-a")
    review("w-b", "Verdict: changes. Revise.")
    expect(runs_woken).to be_empty
  end
end
