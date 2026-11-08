require "spec_helper"
require_relative "support/stand_in_claude"

# A plan review asked for by event starts the architect's session through AgentRun. A stand-in
# `claude` names its agents and starts a session, so no real session runs: the spec shows the
# request becomes a run keyed by the Work item, and a request past the hop limit starts nothing.
RSpec.describe "a plan review request starting the architect's session" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def request(work, hops, run: work)
    launch("agents", "PlanReview.request!", "run.value=#{run}", "work.value=#{work}", "hops.value=#{hops}",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=review this plan", "--wait").first.to_s
  end

  it "starts a run keyed by the review, naming its Work item, for a request under the hop limit" do
    request("w-start", 1, run: "r-start")
    expect(launch("agent_run.running").first.to_s).to include("r-start", "w-start")
  end

  it "names the run it minted in the result of a request that leaves the key out" do
    out = launch("agents", "PlanReview.request!", "work.value=w-mint", "hops.value=1", "role.value=architect",
                 "repo.value=#{scratch}", "plan.value=review this plan", "--wait").first.to_s
    expect(JSON.parse(out).dig("ids", "run")).to match(/\A\S+\z/)
  end

  def review_again
    request("w-again", 1, run: "r-first")
    close_job("Verdict: sound.")
    launch("agent_run.check!", "to=r-first", "--wait")
    request("w-again", 1, run: "r-second")
  end

  it "reviews a Work item again under a new run once its first review's run has finished", :aggregate_failures do
    expect(review_again).to include("PlanReviewRequested")
    expect(launch("agent_run.tidyable").first.to_s).to include("r-first", "r-second")
    expect(launch("agents", "PlanReview.reviews").first.to_s).to include("r-first", "sound", "r-second")
  end

  it "reads the new session without a reaction refused at the depth cap" do
    expect(request("w-depth", 1)).not_to include("reaction depth")
  end

  def close_job(text)
    state = { state: "done", detail: "reviewed", output: { result: text } }
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", state: "done" }]))
  end

  def verdict_reactions
    @hecks.registry.reaction_log.select { |r| r[:policy] == "RecordTheArchitectsVerdict" }
  end

  it "records the verdict the session closed with on the review", :aggregate_failures do
    request("w-verdict", 1)
    close_job("Verdict: sound with changes. Revise the plan as the findings say.")
    launch("agent_run.check!", "to=w-verdict", "--wait")
    expect(verdict_reactions.last[:delivered]).to be(true)
    expect(launch("agents", "PlanReview.reviews").first.to_s).to include("w-verdict", "changes", "Revise the plan")
  end

  def submit(branch, commit)
    launch("coder", "Submission.submit!", "branch.value=#{branch}", "sha.value=#{commit}", "checkout.value=#{scratch}",
           "clean.value=true", "--wait")
  end

  def reactions(policy) = @hecks.registry.reaction_log.select { |r| r[:policy] == policy }

  it "starts the reviewer's run for a submission, keyed by its commit" do
    submit("w-rev", "abc9001")
    expect(launch("agent_run.running").first.to_s).to include("abc9001")
  end

  it "records the reviewer's judgment, and hands a real bug to a person", :aggregate_failures do
    submit("w-bug", "abc9002")
    close_job("The failing spec is a real_bug: the code is wrong.")
    launch("agent_run.check!", "to=abc9002", "--wait")
    expect(launch("agents", "SubmissionReview.reviews").first.to_s).to include("abc9002", "real_bug")
    expect(reactions("RealBugGoesToAPerson").last[:delivered]).to be(true)
  end

  it "starts the planner's run for a planning request, keyed by the request" do
    launch("agents", "Planning.request!", "plan.value=p-1", "goal.value=plan the agents panel", "role.value=planner",
           "repo.value=#{scratch}", "--wait")
    expect(launch("agent_run.running").first.to_s).to include("p-1")
  end

  it "refuses a planning request that says nothing, and starts no run", :aggregate_failures do
    out = launch("agents", "Planning.request!", "plan.value=p-2", "goal.value=", "role.value=planner",
                 "repo.value=#{scratch}", "--wait").first.to_s
    expect(out).to include("says something")
    expect(launch("agent_run.running").first.to_s).not_to include("p-2")
  end

  it "starts no run for a request at the hop limit", :aggregate_failures do
    expect(request("w-stop", 3)).to include("under the hop limit")
    expect(launch("agent_run.running").first.to_s).not_to include("w-stop")
  end
end
