require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# `AgentRun.Rebind` and the sweep's pinned-role count, through the booted Hecks domain: a started
# run moves to a named live session no other run holds, and is refused one that is not live or is
# bound already; `check_all!` reports a pinned role with two live sessions as a finding. A
# stand-in `claude` lists the sessions from a scratch file and starts each session under the id
# in `next-id`, so no real session is touched; the AgentRun ledger is in Memory.
RSpec.describe "AgentRun.Rebind and the doubled pinned role" do
  REBIND_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "stop" ]; then exit 0; fi
    echo "backgrounded · $(cat "$here/next-id")"
  SH

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("rebind")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), REBIND_STAND_IN)
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

  # The sessions `claude agents` lists, each `[id, name, state]`.
  def listing(*sessions)
    entries = sessions.map { |id, name, state| { id: id, sessionId: "#{id}-full", name: name, state: state } }
    File.write(File.join(scratch, "sessions.json"), JSON.generate(entries))
  end

  # Starts a coder run under the session id `session`, whose job reads blocked.
  def started(run, session)
    File.write(File.join(scratch, "next-id"), session)
    FileUtils.mkdir_p(File.join(scratch, "jobs", session))
    File.write(File.join(scratch, "jobs", session, "state.json"), JSON.generate(state: "blocked"))
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")
  end

  def rebind(run, session)
    out = launch("agent_run.rebind!", "to=#{run}", "session.value=#{session}", "--wait").first.to_s
    JSON.parse(out[/\{.*\}/m]).fetch("state")
  end

  def sweep = launch("agent_run.check_all!", "--wait").first.to_s

  it "moves the run to a named live session, keeping the one it held as forked_from" do
    listing
    started("r-move", "first-1")
    listing(["first-1", "coder", "blocked"], ["second-1", "coder", "working"])

    expect(rebind("r-move", "second-1")).to include("session" => "second-1", "forked_from" => "first-1")
  end

  it "refuses a session that is not live, and the run stays on its own", :aggregate_failures do
    listing
    started("r-dead", "first-2")
    listing(["first-2", "coder", "blocked"], ["gone-2", "coder", "stopped"])

    expect(rebind("r-dead", "gone-2")).to include("session" => "first-2", "status" => "started")
    expect(rebind("r-dead", "gone-2")["refusal"]).to include("not live")
  end

  it "refuses a session another started run is bound to, naming that run" do
    listing
    started("r-held", "first-3")
    started("r-other", "other-3")
    listing(["first-3", "coder", "blocked"], ["other-3", "coder", "working"])

    expect(rebind("r-held", "other-3")["refusal"]).to include("already bound to run r-other")
  end

  it "reports a pinned role with two live sessions as a finding of check_all!", :aggregate_failures do
    listing(["orch-a", "ORCHESTRATOR", "working"], ["orch-b", "orchestrator 2", "blocked"])
    out = sweep

    expect(out).to include("PinnedRoleDoubled")
    expect(out).to include("orchestrator: orch-a orch-b")
  end

  it "reports no finding for a pinned role with one live session" do
    listing(["orch-a", "ORCHESTRATOR", "working"], ["orch-b", "orchestrator 2", "done"])

    expect(sweep).not_to include("PinnedRoleDoubled")
  end
end
