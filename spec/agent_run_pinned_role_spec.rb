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
    if [ "$1" = "stop" ]; then exit 0; fi
    if [ "$2" = "--resume" ]; then printf '%s\\n' "$@" > "$here/resume.args"; echo "backgrounded · own-session"; exit 0; fi
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
    FileUtils.mkdir_p(File.join(scratch, "jobs", "own-session"))
    File.write(File.join(scratch, "jobs", "own-session", "state.json"), JSON.generate(state: "blocked"))
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
end
