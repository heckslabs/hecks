require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"

# A coder that asked for a plan review is not read as finished while the review is open, whatever
# its job says, so the architect's verdict can always reach it. The open review is a fact on the
# coder's run (`reviewing`), set by the request and cleared by the verdict, an unstarted review or
# a failed architect run.
RSpec.describe "a coder run whose plan review is open" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }

  def job_reads(state, result: "")
    body = JSON.generate(state: state, output: { result: result })
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), body)
  end

  def coder_state(work) = JSON.parse(launch("agent_run.check!", "to=#{work}", "--wait").first.to_s).fetch("state")

  def verdicts(query) = launch("agents", "Verdict.#{query}").first.to_s

  def coder_waiting_for_review(work)
    wait_as_coder(work)
    request_review(work)
  end

  def done_while_reviewed(work)
    coder_waiting_for_review(work)
    job_reads("done", result: "")
    coder_state(work)
  end

  it "stays started when its job reads done 16 seconds after the request" do
    coder_waiting_for_review("o-done")
    job_reads("done", result: "")
    expect(coder_state("o-done")).to include("status" => "started")
  end

  it "stays started when its job reads stopped while the review is open" do
    coder_waiting_for_review("o-stopped")
    job_reads("stopped")
    expect(coder_state("o-stopped")).to include("status" => "started")
  end

  it "stays started when it is listed idle with no closing words" do
    coder_waiting_for_review("o-idle")
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", status: "idle" }]))
    job_reads("working", result: "Plan asked.")
    expect(coder_state("o-idle")).to include("status" => "started")
  end

  it "is woken with the verdict once the architect closes", :aggregate_failures do
    done_while_reviewed("o-verdict")
    architect_closes("o-verdict", "Verdict: sound. Build it.")
    expect(runs_woken).to eq(["o-verdict"])
    expect(verdicts("delivered")).to include("r-o-verdict")
  end

  it "ends done once the review is answered and its job reads done", :aggregate_failures do
    coder_waiting_for_review("o-answered")
    architect_closes("o-answered", "Verdict: sound. Build it.")
    job_reads("done", result: "Landed.")
    expect(coder_state("o-answered")).to include("status" => "finished", "condition" => "done")
  end

  it "stays started on a second review once the older one was answered and a new one is open" do
    coder_waiting_for_review("o-twice")
    architect_closes("o-twice", "Verdict: changes. Revise.")
    request_in_review_again("o-twice")
    job_reads("done")
    expect(coder_state("o-twice")).to include("status" => "started")
  end

  it "is told so and free to end when the architect's run failed", :aggregate_failures do
    architect_fails("o-failed")
    job_reads("done", result: "Landed.")
    expect(runs_woken).to eq(["o-failed"])
    expect(coder_state("o-failed")).to include("status" => "finished")
  end

  def judged_after_finishing(work)
    wait_as_coder(work)
    job_reads("done", result: "Landed.")
    coder_state(work)
    launch("agents", "Verdict.judge!", "run.value=j-late", "work.value=#{work}", "role.value=architect",
           "answer.value=Verdict: sound", "--wait")
  end

  def architect_fails(work)
    coder_waiting_for_review(work)
    job_reads("failed")
    launch("agent_run.check!", "to=r-#{work}", "--wait")
  end

  it "records a verdict judged for an already finished coder undeliverable, naming the run and item", :aggregate_failures do
    judged_after_finishing("o-late")
    expect(verdicts("undelivered")).to include("j-late", "o-late")
    expect(runs_woken).to be_empty
  end

  def request_in_review_again(work)
    launch("agents", "PlanReview.request!", "run.value=r2-#{work}", "work.value=#{work}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=plan", "--wait")
  end
end
