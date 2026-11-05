require "spec_helper"
require_relative "support/stand_in_claude"

# A plan review asked for by event starts the architect's session through AgentRun. A stand-in
# `claude` names its agents and starts a session, so no real session runs: the spec shows the
# request becomes a run keyed by the Work item, and a request past the hop limit starts nothing.
RSpec.describe "a plan review request starting the architect's session" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def request(work, hops)
    launch("agents", "PlanReview.request!", "work.value=#{work}", "hops.value=#{hops}", "role.value=architect",
           "repo.value=#{scratch}", "plan.value=review this plan", "--wait").first.to_s
  end

  it "starts a run keyed by the Work item for a request under the hop limit" do
    request("w-start", 1)
    expect(launch("agent_run.running").first.to_s).to include("w-start")
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
    expect(verdict_reactions.map { |r| r[:delivered] }).to eq([true])
    expect(launch("agents", "PlanReview.reviews").first.to_s).to include("w-verdict", "changes", "Revise the plan")
  end

  def submit(branch, commit)
    launch("coder", "Submission.submit!", "branch.value=#{branch}", "sha.value=#{commit}", "--wait")
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
