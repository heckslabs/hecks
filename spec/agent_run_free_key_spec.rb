require "spec_helper"
require_relative "support/stand_in_claude"

# An `AgentRun` that has ended frees its key: a new dispatch under it starts a new run, and the
# ended one stays readable as `<run>~<n>`. A run in no declared state frees its key too; a started
# run keeps it. A stand-in `claude` and a scratch jobs directory keep every session fake, and the
# runtime is in Memory, so no ledger under the owner's home is touched.
RSpec.describe "AgentRun freeing the key of an ended run" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def request(run, work)
    launch("agents", "PlanReview.request!", "run.value=#{run}", "work.value=#{work}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=review this plan", "--wait").first.to_s
  end

  def dispatch(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok",
           "agent.value=architect", "--wait").first.to_s
  end

  def job_state(state)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
  end

  # Ends the run's job, then sets the stand-in's job back to working, as the next session's is.
  def finish(run)
    job_state(state: "done", detail: "reviewed", output: { result: "Verdict: sound." })
    launch("agent_run.check!", "to=#{run}", "--wait")
    job_state(state: "working")
  end

  def store(domain, aggregate)
    @hecks.registry.repository(domain, @hecks.registry.bluebook(domain).aggregate(aggregate))
  end

  def status_of(run) = store("Hecks", "AgentRun").find(run)[:status]

  # The Agents domain is Memory per process while the run ledger outlives it, so a later process
  # holds the finished run but not the review that started it.
  def review_in_a_later_process(run, work)
    request(run, work)
    finish(run)
    store("Agents", "PlanReview").delete(run)
    request(run, work)
  end

  it "starts a new architect run for a review asked after the first run finished", :aggregate_failures do
    expect(review_in_a_later_process("r-free", "w-free")).to include("PlanReviewRequested")
    expect(status_of("r-free")).to eq("started")
    expect(status_of("r-free~1")).to eq("finished")
  end

  it "runs a repeat dispatch through the launcher once the run under the key has finished", :aggregate_failures do
    dispatch("d-free")
    finish("d-free")
    expect(dispatch("d-free")).to include("AgentRunRequested")
    expect([status_of("d-free"), status_of("d-free~1")]).to eq(%w[started finished])
  end

  it "frees the key of a run in no queryable state", :aggregate_failures do
    dispatch("d-odd")
    store("Hecks", "AgentRun").find("d-odd")[:status] = "vanished"
    dispatch("d-odd")
    expect(status_of("d-odd")).to eq("started")
    expect(status_of("d-odd~1")).to eq("vanished")
  end

  it "refuses a second dispatch of a working run's key by name", :aggregate_failures do
    dispatch("d-busy")
    expect(dispatch("d-busy")).to include("refused", "d-busy")
    expect(store("Hecks", "AgentRun").find("d-busy~1")).to be_nil
  end

  it "refuses a working run's key in the runtime as already existing" do
    dispatch("d-held")
    expect do
      @hecks.dispatch_flat("Hecks::AgentRun.Dispatch", run: { value: "d-held" }, repo: { value: scratch },
                                                       brief: { value: "again" })
    end.to raise_error(Hecks::Runtime::AlreadyExists)
  end
end
