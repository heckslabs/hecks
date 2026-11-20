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
           "role.value=architect", "repo.value=#{scratch}", "plan.value=review this plan as written", "--wait").first.to_s
  end

  it "starts a run keyed by the review, naming its Work item, for a request under the hop limit" do
    request("w-start", 1, run: "r-start")
    expect(launch("agent_run.running").first.to_s).to include("r-start", "w-start")
  end

  it "names the run it minted in the result of a request that leaves the key out" do
    out = launch("agents", "PlanReview.request!", "work.value=w-mint", "hops.value=1", "role.value=architect",
                 "repo.value=#{scratch}", "plan.value=review this plan as written", "--wait").first.to_s
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

  it "judges the architect's verdict for the coder waiting on the Work item" do
    request("w-judge", 1)
    close_job("Verdict: sound. Build it.")
    launch("agent_run.check!", "to=w-judge", "--wait")
    expect(reactions("JudgeTheForwardedVerdict").map { |r| r[:delivered] }).to include(true)
  end

  def verdict_of(run) = @hecks.registry.repository("Agents", @hecks.registry.bluebook("Agents").aggregate("Verdict")).find(run)

  # The names of the events one check of a run records, in the order they were recorded.
  def events_of_check(run)
    before = @hecks.registry.event_log.size
    launch("agent_run.check!", "to=#{run}", "--wait")
    @hecks.registry.event_log.drop(before).map(&:name)
  end

  def review_and_check(work, text)
    request(work, 1)
    close_job(text)
    events_of_check(work)
  end

  it "answers the requested review in the Agents domain before the coder is judged the verdict", :aggregate_failures do
    names = review_and_check("w-stored", "Verdict: rethink. Start over.")
    expect(reactions("RecordTheArchitectsVerdict").last[:delivered]).to be(true)
    expect(names.index("PlanReviewed")).to be < names.index("VerdictJudged")
    expect(names.count("VerdictJudged")).to eq(1)
    expect(verdict_of("w-stored")).not_to be_nil
  end

  # The review is asked again past its window, which ends it, before the verdict is read.
  def answer_after_the_end(run)
    request("w-late", 1, run: run)
    launch("agents", "PlanReview.reask!", "to=#{run}", "work.value=w-late", "hops.value=1", "role.value=architect",
           "repo.value=#{scratch}", "plan.value=review this plan as written", "now.value=4102444800", "--wait")
    close_job("Verdict: sound. Build it.")
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  it "judges no verdict for the coder when the review it answers had already ended" do
    answer_after_the_end("r-late")
    expect(verdict_of("r-late")).to be_nil
  end

  def hand_start(run, work)
    served = work ? ["work.value=#{work}"] : []
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=review", "agent.value=architect",
           *served, "--wait")
    close_job("Verdict: rethink. Start over.")
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  it "records the verdict of a run no review row names, on the Work item the run serves", :aggregate_failures do
    hand_start("r-orphan", "w-orphan")
    expect(reactions("RecordTheVerdictWhenNoReviewWasAsked").last[:delivered]).to be(true)
    expect(reactions("JudgeTheRecordedReview").last[:delivered]).to be(true)
    expect(launch("agents", "PlanReview.reviews").first.to_s).to include("r-orphan", "w-orphan", "rethink")
  end

  it "records no verdict for a hand-started run that serves no Work item" do
    hand_start("r-nowork", nil)
    expect(launch("agents", "PlanReview.reviews").first.to_s).not_to include("r-nowork")
  end

  def submit(branch, commit)
    launch("coder", "Submission.submit!", "branch.value=#{branch}", "sha.value=#{commit}", "checkout.value=#{scratch}",
           "clean.value=true", "--wait")
  end

  def reactions(policy) = @hecks.registry.reaction_log.select { |r| r[:policy] == policy }

  def runs = @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("AgentRun"))

  it "starts the reviewer's run for a submission, keyed by its commit" do
    submit("w-rev", "abc9001")
    expect(launch("agent_run.running").first.to_s).to include("abc9001")
  end

  it "records the reviewer's judgment, and raises a real bug for its route to a coder", :aggregate_failures do
    submit("w-bug", "abc9002")
    close_job("The failing spec is wrong code, not a stale expectation.\n\nreal_bug")
    launch("agent_run.check!", "to=abc9002", "--wait")
    expect(launch("agents", "SubmissionReview.reviews").first.to_s).to include("abc9002", "real_bug")
    expect(reactions("RaiseTheFinding").last[:delivered]).to be(true)
  end

  it "records a missing behavior with the reviewer's report as its findings" do
    submit("w-gap", "abc9003")
    close_job("No scenario in lib/hecks/agents covers SubmissionReview.Judge with findings.\n\nmissing_behavior")
    launch("agent_run.check!", "to=abc9003", "--wait")
    expect(launch("agents", "SubmissionReview.reviews").first.to_s).to include("missing_behavior", "covers SubmissionReview")
  end

  def planner_runs = runs.all.select { |run| run[:agent]&.value == "planner" }

  it "starts the planner's run for a planning request, under a minted key", :aggregate_failures do
    before = planner_runs.size
    launch("agents", "Planning.request!", "plan.value=p-1", "goal.value=plan the agents panel", "role.value=planner",
           "repo.value=#{scratch}", "--wait")
    expect(planner_runs.size).to eq(before + 1)
    expect(runs.find("p-1")).to be_nil
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
