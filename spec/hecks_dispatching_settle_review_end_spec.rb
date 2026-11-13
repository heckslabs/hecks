require "spec_helper"
require_relative "support/stand_in_claude"
require "hecks/hecks/adapters/dispatching"

# The sequence of 2026-11-13, 13:58:24Z to 13:59:39Z, replayed on a Memory boot: a Work item whose
# earlier coder run finished is started again, its new coder asks for a plan review, the review's
# session ends, and a settle follows. The earlier run is archived as `<work>~1` with its `run`
# field still the Work item's key, so it must never be read as the live coder's run: the settle
# yields nothing, and once the coder is answered the item is still started.
RSpec.describe Hecks::Adapters::Dispatching::Settler, "#call" do
  include_context "with a stand-in claude"

  let(:key) { "stall-abandon-pruned-runs" }
  let(:registry) { boot_hecks_in_memory.registry }
  let(:runner) { Hecks::Adapters::Dispatching::InProcessRunner.new(registry) }
  let(:launcher) { instance_double(Hecks::Adapters::Dispatching::Launcher, **launcher_answers) }

  def launcher_answers = { check_all: nil, yield_back: "y", finish: "f", report_unlanded: "u" }

  def launch(*argv) = runner.call([*argv, "--wait"])

  def job(state) = File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))

  def dispatch(run, state)
    job(state)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=build it")
    launch("agent_run.check!", "to=#{run}")
  end

  # The Work item started, an earlier attempt of its coder finished done, and the new coder working.
  def restarted_coder
    launch("tickets", "Work.plan!", "work.value=#{key}", "title.value=Stall: abandon pruned runs")
    launch("tickets", "Work.start!", "to=#{key}", "claimed_by.value=dispatch", "claimed_at.value=#{Time.now.utc.iso8601}")
    dispatch(key, "done")
    dispatch(key, "working")
  end

  def review_ends
    launch("agents", "PlanReview.request!", "run.value=r-1", "work.value=#{key}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=review this plan")
    job("done")
    launch("agent_run.check!", "to=r-1")
  end

  def settle = described_class.new(Hecks::Adapters::Dispatching::WorkItems.new(registry), launcher).call

  def status(run) = Hecks::Adapters::Dispatching::WorkItems.new(registry).runs.dig(run, :status)

  it "reads the live coder's run under the key, not its archived attempt" do
    restarted_coder

    expect(status(key)).to eq("started")
  end

  it "yields nothing when the review's session ends while the coder waits", :aggregate_failures do
    restarted_coder
    review_ends

    expect(settle).to eq([])
    expect(launcher).not_to have_received(:yield_back)
  end

  it "keeps the item started once the coder is answered", :aggregate_failures do
    restarted_coder
    review_ends
    launch("agent_run.answered!", "to=#{key}", "answered_at.value=#{Time.now.utc.iso8601}", "session.value=stand-in-session")

    expect(settle).to eq([])
    expect(Hecks::Adapters::Dispatching::WorkItems.new(registry).started.map(&:key)).to eq([key])
  end
end
