require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# A pinned role has one live session, through the booted Hecks domain: a run of the orchestrator
# role is declined while another live session holds it, and a started orchestrator run is not
# answered until that session ends. A stand-in `claude` lists the sessions from a scratch file and
# records each resume, so no real session is touched; the AgentRun ledger is in Memory.
RSpec.describe "AgentRun keeps one live session per pinned role" do
  PINNED_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "stop" ]; then [ -f "$here/resume.args" ] && echo "$2" >> "$here/stopped"; [ -f "$here/stop-fails" ] && exit 1; exit 0; fi
    if [ "$2" = "--resume" ]; then
      printf '%s\\n' "$@" > "$here/resume.args"
      if [ -f "$here/copy" ]; then echo "note: started a copy as copy-1" >&2; echo "backgrounded · copy-1"; else echo "backgrounded · own-session"; fi
      exit 0
    fi
    echo "backgrounded · own-session"
  SH

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("pinned-role")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), PINNED_STAND_IN)
    File.chmod(0o755, File.join(scratch, "claude"))
    ENV["PATH"] = "#{scratch}:#{env["PATH"]}"
    ENV["HOME"] = scratch
    example.run
  ensure
    ENV.update(env)
    FileUtils.rm_rf(scratch)
  end

  before do
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0, inbox: File.join(scratch, "inbox") })
    end)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  # The sessions `claude agents` lists, each `[id, name, state]`, and the job of the run's own one.
  def listing(*sessions)
    entries = sessions.map { |id, name, state| { id: id, sessionId: "#{id}-full", name: name, state: state } }
    File.write(File.join(scratch, "sessions.json"), JSON.generate(entries))
    %w[own-session copy-1].each do |id|
      FileUtils.mkdir_p(File.join(scratch, "jobs", id))
      File.write(File.join(scratch, "jobs", id, "state.json"), JSON.generate(state: "blocked"))
    end
  end

  # The sessions stopped after a resume, not the stop a resume makes of a blocked session first.
  def stopped = File.exist?(File.join(scratch, "stopped")) ? File.read(File.join(scratch, "stopped")).split : []

  # A started run whose next answer's resume starts a copy, `copy-1`, of its own session.
  def forking(run, role)
    listing
    dispatch(run, role)
    listing(["own-session", "orchestrator", "blocked"])
    File.write(File.join(scratch, "copy"), "yes")
  end

  def dispatch(run, role)
    out = launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok",
                 "works_as.value=#{role}", "--wait")
    JSON.parse(out.first.to_s).fetch("state")
  end

  def answer(run) = launch("agent_run.answer!", "to=#{run}", "answer.value=go on", "--wait").first.to_s

  it "declines a second orchestrator run while a live session holds the role, naming it", :aggregate_failures do
    listing(["old-orch", "ORCHESTRATOR", "working"])
    state = dispatch("p-second", "orchestrator")

    expect(state).to include("status" => "refused")
    expect(state["refusal"]).to include("pinned role orchestrator already has a live session old-orch")
  end

  it "starts a run of a role no PinnedRole row names, whatever else is live" do
    listing(["old-orch", "ORCHESTRATOR", "working"])

    expect(dispatch("p-coder", "coder")).to include("status" => "started")
  end

  it "starts an orchestrator run while only an orchestrator-owner session is live" do
    listing(["owner-1", "orchestrator-owner", "working"])

    expect(dispatch("p-owner", "orchestrator")).to include("status" => "started")
  end

  it "starts an orchestrator run while the other orchestrator session is idle between turns" do
    listing(["old-orch", "ORCHESTRATOR", "done"])

    expect(dispatch("p-idle", "orchestrator")).to include("status" => "started")
  end

  it "refuses to answer the orchestrator run while another live session holds the role", :aggregate_failures do
    listing
    dispatch("p-answer", "orchestrator")
    listing(["own-session", "orchestrator", "blocked"], ["old-orch", "orchestrator 2", "working"])

    expect(answer("p-answer")).to include("already has a live session old-orch")
    expect(File.exist?(File.join(scratch, "resume.args"))).to be(false)
  end

  it "answers the orchestrator run again once the other session has ended", :aggregate_failures do
    listing
    dispatch("p-cleared", "orchestrator")
    listing(["own-session", "orchestrator", "blocked"], ["old-orch", "orchestrator 2", "stopped"])

    expect(answer("p-cleared")).to include("answered_at")
    expect(File.read(File.join(scratch, "resume.args"))).to include("[pipeline answer] go on")
  end

  it "stops the session an orchestrator run held once a fork's resume left it for a copy" do
    forking("p-fork", "orchestrator")
    answer("p-fork")

    expect(stopped).to eq(["own-session"])
  end

  it "leaves the session a coder run held when its resume forks, since no PinnedRole row names it" do
    forking("p-coder-fork", "coder")
    answer("p-coder-fork")

    expect(stopped).to be_empty
  end

  it "keeps refusing the forked run's answers by name while a refused stop left the old session live" do
    forking("p-stuck", "orchestrator")
    File.write(File.join(scratch, "stop-fails"), "yes")
    answer("p-stuck")
    listing(["copy-1", "orchestrator 2", "blocked"], ["own-session", "orchestrator", "working"])

    expect(answer("p-stuck")).to include("already has a live session own-session")
  end
end
