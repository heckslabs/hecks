require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# `AgentRun` through the booted Hecks domain, with a stand-in `claude` first on the search path and
# a scratch jobs directory: a dispatch is requested, the directory and the agent are looked for, a
# session is started and recorded, and a check records each change of the job's state as one
# event. The stand-in names the agents it has, prints the session id a spec writes, and records
# each start, so no real session is ever started.
RSpec.describe "AgentRun through the Agents port" do
  AGENT_RUN_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "--agent" ] && [ "$3" = "-p" ]; then
      echo "--agent '$2' not found. Available agents: claude, Explore, coder" >&2; exit 1
    fi
    echo started >> "$here/starts"
    printf 'backgrounded · %s\\n  claude agents    list sessions\\n' "$(cat "$here/next_session")"
  SH

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-run")) }
  let(:jobs) { File.join(scratch, "jobs") }

  around do |example|
    path = ENV.fetch("PATH")
    install_stand_in
    ENV["PATH"] = "#{scratch}:#{path}"
    example.run
  ensure
    ENV["PATH"] = path
    FileUtils.rm_rf(scratch)
  end

  before do
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: jobs, settle: 0 })
    end)
  end

  def install_stand_in
    File.write(File.join(scratch, "claude"), AGENT_RUN_STAND_IN)
    File.chmod(0o755, File.join(scratch, "claude"))
    next_session("stand-in-session")
  end

  def next_session(id) = File.write(File.join(scratch, "next_session"), id)

  def job(session, state, detail = nil)
    FileUtils.mkdir_p(File.join(jobs, session))
    File.write(File.join(jobs, session, "state.json"), JSON.generate(state: state, detail: detail))
  end

  def starts = File.exist?(File.join(scratch, "starts")) ? File.readlines(File.join(scratch, "starts")).size : 0

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def dispatch(run, repo: scratch, agent: nil)
    named = agent ? ["agent.value=#{agent}"] : []
    JSON.parse(launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{repo}", "brief.value=say ok", *named,
                      "--wait").first)
  end

  def check(run) = JSON.parse(launch("agent_run.check!", "to=#{run}", "--wait").first)

  def session_events(out) = out["events"].grep(/\ASession/)

  def running = JSON.parse(launch("query", "agent_run.running").first)

  it "starts a session in a directory that is there, and lists it as running", :aggregate_failures do
    out = dispatch("a-start")

    expect(out.dig("state", "status")).to eq("started")
    expect(running.map { |row| row["session"] }).to include("stand-in-session")
  end

  it "declines a directory that is not there, and lists nothing as running", :aggregate_failures do
    out = dispatch("a-absent", repo: File.join(scratch, "absent"))

    expect(out.dig("state", "status")).to eq("refused")
    expect(running.map { |row| row["run"] }).not_to include("a-absent")
  end

  it "refuses an agent the directory's claude does not list, before any session starts", :aggregate_failures do
    out = dispatch("a-bad-agent", agent: "no-such-agent")

    expect(out.dig("state", "refusal")).to include("agent no-such-agent is not available", "claude, Explore, coder")
    expect(starts).to eq(0)
  end

  it "starts a session for an agent the directory's claude lists" do
    expect(dispatch("a-coder", agent: "coder").dig("state", "status")).to eq("started")
  end

  # A dispatch whose job has already failed by the time it is read.
  def dispatch_dead
    next_session("dead-session")
    job("dead-session", "failed", "exit 1 before init")
    dispatch("a-dead")
  end

  # Dispatches a run, then checks it once per state, answering the session events the run holds.
  def walk(run, *states)
    dispatch(run)
    outs = states.map do |state|
      job("stand-in-session", state, "#{state} detail")
      check(run)
    end
    session_events(outs.last)
  end

  def last_payload(name)
    Hecks::Runtime::Value.materialize(@hecks.registry.event_log.reverse.find { |event| event.name == name }.payload)
  end

  it "records a session whose job died at once as failed, never as started", :aggregate_failures do
    out = dispatch_dead

    expect(out.dig("state", "status")).to eq("finished")
    expect(out["events"]).to include("SessionFailed")
    expect(out.dig("state", "detail")).to eq("exit 1 before init")
  end

  it "records each change of the job's state as one event, and nothing when it did not change" do
    expect(walk("a-life", "working", "working", "blocked", "blocked", "working", "done"))
      .to eq(%w[SessionWorking SessionBlocked SessionWorking SessionFinished])
  end

  it "keeps the question a blocked session waits on" do
    walk("a-blocked", "blocked")

    expect(last_payload("SessionBlocked")[:detail]).to eq(value: "blocked detail")
  end

  it "names the run's directory, with its trailing slash, on each session event" do
    walk("a-path", "working")

    expect(last_payload("SessionWorking")[:checkout]).to eq(value: "#{scratch}/")
  end

  it "finishes a run whose job reports done, so it is no longer running" do
    dispatch("a-done")
    job("stand-in-session", "done")
    check("a-done")

    expect(running.map { |row| row["run"] }).not_to include("a-done")
  end

  # One run whose job has ended and one still started, then one sweep.
  def sweep
    next_session("sweep-ended")
    job("sweep-ended", "done")
    dispatch("a-sweep-ended")
    next_session("sweep-live")
    dispatch("a-sweep-live")
    checks_during { launch("agent_run.check_all!", "--wait") }
  end

  # The runs a block checked, read from the events it logged.
  def checks_during
    log = @hecks.registry.event_log
    seen = log.size
    yield
    log.to_a.drop(seen).select { |event| event.name == "AgentCheckRequested" }.map { |event| event.id.to_s }
  end

  it "checks every started run in one sweep, and no run that has ended", :aggregate_failures do
    checked = sweep

    expect(checked).to match_array(running.map { |row| row["run"] })
    expect(checked).to include("a-sweep-live")
    expect(checked).not_to include("a-sweep-ended")
  end
end
