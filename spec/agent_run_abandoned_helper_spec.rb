require "spec_helper"
require "time"
require_relative "support/stand_in_claude"

# A helper session blocked on a question nobody answers ends itself. Through the booted Hecks
# domain, whose world gives a blocked helper `abandon_after_minutes` (30): a reviewer blocked past
# it ends its run `abandoned` with its question kept, and the reap that follows removes its
# session; one blocked under it, a coder, the standing seat, a session `pins.json` names, a trial
# run, one in a world that sets no time and one answered in time all stay started. A stall fixer's
# run is a helper too: it ends the same way, its kept session is stopped, and `retire!` of one
# whose session is still listed is refused with the reason.
# The stand-in `claude` lists the session and logs each `rm`.
RSpec.describe "AgentRun: a helper blocked with no answer" do
  include_context "with a stand-in claude"

  FULL_SESSION = "5e55a0a0-1111-2222-3333-444455556666".freeze

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  # The examples share one registry and one stand-in session, so a pinned role (the orchestrator's)
  # would be read as held by the run an earlier example left started, and its dispatch declined.
  before do
    allow(Hecks::Adapters::Dispatching::WorkItems).to(receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |items| allow(items).to receive(:pinned_roles).and_return([]) }
    end)
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
      original.call(*args).tap { |items| allow(items).to receive_messages(work_status: "planned", pinned_roles: []) }
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

  it "removes an abandoned planner's session though its Work is still queued" do
    work_still_queued
    quiet_transcript
    blocked_run("ab-planner", "planner", 40)
    expect(status_of("ab-planner")).to include(status: "tidied")
  end

  it "leaves a reviewer blocked under the time started" do
    expect(blocked_run("ab-young", "reviewer", 10)).to include("status" => "started")
  end

  it "leaves a coder blocked past the time started, waiting on the owner" do
    expect(blocked_run("ab-coder", "coder", 40)).to include("status" => "started")
  end

  it "leaves the standing seat blocked past the time started" do
    expect(blocked_run("orchestrator-seat", "orchestrator", 40)).to include("status" => "started")
  end

  it "ends a stall run blocked past the time abandoned and removes its session", :aggregate_failures do
    quiet_transcript
    blocked_run("stall-ab-train", "orchestrator", 40)
    expect(status_of("stall-ab-train")).to include(condition: { value: "abandoned" }, status: "tidied")
    expect(removed).to include("stand-in-session")
  end

  it "leaves a stall run blocked under the time started" do
    expect(blocked_run("stall-ab-young", "orchestrator", 10)).to include("status" => "started")
  end

  # The reap finds uncommitted files in the worktree of every session it reviews.
  def unsaved_work
    allow(Hecks::Adapters::SessionReaping).to(receive(:new).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |reaping|
        allow(reaping).to(receive(:facts).and_wrap_original { |facts, *held| facts.call(*held).merge(dirty: true) })
      end
    end)
  end

  def stops = @hecks.registry.event_log.map(&:name).count("SessionStopped")

  it "stops the session of an abandoned stall run the reap keeps for its unsaved work", :aggregate_failures do
    quiet_transcript
    unsaved_work
    expect { blocked_run("stall-ab-kept", "orchestrator", 40) }.to change { stops }.by_at_least(1)
    expect(removed).not_to include("stand-in-session")
  end

  # A stall run whose job reads blocked for `minutes`, not checked since it blocked.
  def unchecked_stall(run, minutes)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=fix the stall",
           "agent.value=orchestrator", "--wait")
    job("blocked", minutes)
  end

  def retire(run) = launch("AgentRun.retire!", "to=#{run}", "--wait")

  def refused = Hecks::Adapters::Driving::ExitStatus::REFUSED

  def answered = Hecks::Adapters::Driving::ExitStatus::ANSWERED

  it "refuses to retire a stall run blocked past the time whose session is still listed", :aggregate_failures do
    unchecked_stall("stall-ab-listed", 40)
    answer, status, why = retire("stall-ab-listed")
    expect([status, why]).to match([refused, a_string_including("is not retired")])
    expect(JSON.parse(answer).dig("state", "refusal")).to eq("session stand-in-session is still listed, blocked")
  end

  # The listing holds no session, and a started session is given no time to appear.
  def session_gone
    File.write(File.join(scratch, "sessions.json"), "[]")
    allow(Hecks::Adapters::SessionLookup).to(receive(:new).and_wrap_original do |lookup, listing, **rest|
      lookup.call(listing, **rest, grace: -> { 0 })
    end)
  end

  it "retires a stall run blocked past the time whose session is gone" do
    unchecked_stall("stall-ab-gone", 40)
    session_gone
    answer, status = retire("stall-ab-gone")
    expect([JSON.parse(answer).dig("state", "status"), status]).to eq(["retired", answered])
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
