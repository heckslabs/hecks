require "spec_helper"
require "time"
require_relative "support/stand_in_claude"

# A helper session blocked on a question nobody answers ends itself. Through the booted Hecks
# domain, whose world gives a blocked helper `abandon_after_minutes` (30): a reviewer blocked past
# it ends its run `abandoned` with its question kept, and the reap that follows removes its
# session; one blocked under it, a coder, the orchestrator, a session `pins.json` names, a trial
# run, one in a world that sets no time and one answered in time all stay started.
# The stand-in `claude` lists the session and logs each `rm`.
RSpec.describe "AgentRun: a helper blocked with no answer" do
  include_context "with a stand-in claude"

  FULL_SESSION = "5e55a0a0-1111-2222-3333-444455556666".freeze

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def check(run) = JSON.parse(launch("agent_run.check!", "to=#{run}", "--wait").first.to_s).fetch("state")

  def removed = File.exist?(File.join(scratch, "rm.log")) ? File.readlines(File.join(scratch, "rm.log"), chomp: true) : []

  # The job reads `state`, written `minutes` ago, waiting on the question; the listing agrees.
  def job(state, minutes)
    stamp = (Time.now.utc - (minutes * 60)).iso8601(3)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"),
               JSON.generate(state: state, detail: "which branch do I review?", updatedAt: stamp))
    listing = [{ id: "stand-in-session", sessionId: FULL_SESSION, state: state }]
    File.write(File.join(scratch, "sessions.json"), JSON.generate(listing))
  end

  # A transcript in which nobody but the brief spoke, so the reap may remove the session.
  def quiet_transcript
    dir = File.join(scratch, ".claude", "projects", "p")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{FULL_SESSION}.jsonl"), JSON.generate(type: "user", message: { content: "review" }))
  end

  def blocked_run(run, agent, minutes)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=review",
           "agent.value=#{agent}", "--wait")
    check(run)
    job("blocked", minutes)
    check(run)
  end

  def work_still_queued
    allow(Hecks::Adapters::Dispatching::WorkItems).to(receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |items| allow(items).to receive(:work_status).and_return("planned") }
    end)
  end

  def status_of(run)
    runs = @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("AgentRun"))
    Hecks::Runtime::Value.materialize(runs.find(run).state)
  end

  it "ends a reviewer blocked past the time abandoned, keeping its question, and removes its session", :aggregate_failures do
    quiet_transcript
    blocked_run("ab-reviewer", "reviewer", 40)

    expect(status_of("ab-reviewer")).to include(condition: { value: "abandoned" }, detail: { value: "which branch do I review?" })
    expect(status_of("ab-reviewer")).to include(status: "tidied")
    expect(removed).to include("stand-in-session")
  end

  it "removes an abandoned release manager's session though its Work is still queued" do
    work_still_queued
    quiet_transcript
    blocked_run("ab-release", "release_manager", 40)
    expect(status_of("ab-release")).to include(status: "tidied")
  end

  it "leaves a reviewer blocked under the time started" do
    expect(blocked_run("ab-young", "reviewer", 10)).to include("status" => "started")
  end

  it "leaves a coder blocked past the time started, waiting on the owner" do
    expect(blocked_run("ab-coder", "coder", 40)).to include("status" => "started")
  end

  it "leaves the orchestrator blocked past the time started" do
    expect(blocked_run("ab-orchestrator", "orchestrator", 40)).to include("status" => "started")
  end

  it "leaves a helper whose session pins.json names started" do
    File.write(File.join(scratch, "jobs", "pins.json"), JSON.generate(["stand-in"]))
    expect(blocked_run("ab-pinned", "reviewer", 40)).to include("status" => "started")
  end

  it "leaves a helper blocked past the time started when the world sets no time" do
    allow(Hecks::Adapters::SessionReaping).to(receive(:new).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap { |reaping| allow(reaping).to receive(:abandon_after).and_return(0) }
    end)
    expect(blocked_run("ab-unset", "reviewer", 40)).to include("status" => "started")
  end

  it "never ends a trial run's blocked helper abandoned" do
    launch("agent_run.dispatch!", "run.value=live-ab-trial", "repo.value=#{scratch}", "brief.value=review",
           "agent.value=reviewer", "--wait")
    job("blocked", 40)
    launch("agent_run.check!", "to=live-ab-trial", "--wait")
    expect(status_of("live-ab-trial")).not_to include(condition: { value: "abandoned" })
  end

  it "ends an abandoned helper once, though its kept session still reads blocked" do
    blocked_run("ab-again", "reviewer", 40)
    finished = @hecks.registry.event_log.map(&:name).count("SessionFinished")
    launch("agent_run.check!", "to=ab-again", "--wait")
    expect(@hecks.registry.event_log.map(&:name).count("SessionFinished")).to eq(finished)
  end

  # A dispatched reviewer whose job reads blocked under a stamp that is not a time.
  def unstamped_run(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=review",
           "agent.value=reviewer", "--wait")
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"),
               JSON.generate(state: "blocked", detail: "which branch?", updatedAt: "not a time"))
    File.write(File.join(scratch, "sessions.json"),
               JSON.generate([{ id: "stand-in-session", sessionId: FULL_SESSION, state: "blocked" }]))
  end

  it "leaves a helper whose job's stamp cannot be read started" do
    unstamped_run("ab-unstamped")
    expect(check("ab-unstamped")).to include("status" => "started")
  end

  it "leaves a helper answered before the time started" do
    blocked_run("ab-answered", "reviewer", 10)
    job("working", 0)
    expect(check("ab-answered")).to include("status" => "started")
  end
end
