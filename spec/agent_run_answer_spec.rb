require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# `AgentRun.Answer` through the booted Hecks domain, by the paths of the
# `AnswerTheSessionWhereItIs` rule: a session listed busy that carries the inbox hook gets the
# answer in its inbox and is never stopped, a busy one without the hook is refused by name and
# not stopped, and an idle or gone one is resumed with the answer. An empty answer is refused. A
# stand-in `claude` (the session lister and the port's commands) records each `stop` and
# `--resume`, so no real session is touched, and the inbox is a temporary directory. The
# adapter's argument list and directory are in claude_agents_spec.rb.
RSpec.describe "AgentRun.Answer through the Agents port" do
  ANSWER_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    polls() { if [ -f "$here/stopped" ]; then cat "$here/polls" 2>/dev/null || echo 0; else echo 99; fi; }
    if [ "$1" = "agents" ]; then
      n=$(polls); echo $((n + 1)) > "$here/polls"
      if [ -f "$here/stopped" ] && [ "$n" -ge 2 ]; then sed 's/"state":"[a-z]*"/"state":"stopped"/' "$here/sessions.json"; else cat "$here/sessions.json"; fi
      exit 0
    fi
    if [ "$1" = "stop" ]; then echo "$2" >> "$here/stopped"; echo 0 > "$here/polls"; exit 0; fi
    if [ "$2" = "--resume" ]; then
      printf '%s\\n' "$@" > "$here/resume.args"
      if [ -f "$here/copy" ] || [ "$(polls)" -lt 2 ]; then
        echo "note: the flags you passed started a copy as copy-session-1" >&2; echo "backgrounded · copy-session-1"
      else
        echo "note: woke session with its saved options." >&2; echo "backgrounded · stand-in-session"
      fi
      exit 0
    fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-answer")) }
  let(:resume_args) { File.join(scratch, "resume.args") }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), ANSWER_STAND_IN)
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
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0, inbox: inbox })
    end)
  end

  def inbox = File.join(scratch, "inbox")

  def job_dir = File.join(scratch, "jobs", "stand-in-session")

  # The session as `claude agents` lists it (`status:` busy or idle, when given), and its job's
  # state in `state`, with any other job fields (`respawnFlags`).
  def sessions(state, status: nil, **job)
    listed = { id: "stand-in-session", sessionId: "stand-in-session-0000-full", state: state, status: status }.compact
    File.write(File.join(scratch, "sessions.json"), JSON.generate([listed]))
    FileUtils.mkdir_p(job_dir)
    File.write(File.join(job_dir, "state.json"), JSON.generate(state: state, **job))
  end

  # The job fields of a session started with the run's inbox hook in its settings.
  def hooked(run) = { respawnFlags: ["--settings", JSON.generate(hooks: "f=#{File.join(inbox, "#{run}.md")}")] }

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def started_run(run, state, **listing)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")
    sessions(state, **listing)
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def answer(run, text, *more) = launch("agent_run.answer!", "to=#{run}", "answer.value=#{text}", *more, "--wait").first.to_s

  def touched? = File.exist?(File.join(scratch, "stopped")) || File.exist?(resume_args)

  def check(run) = JSON.parse(launch("agent_run.check!", "to=#{run}", "--wait").first.to_s).fetch("state")

  it "leaves the answer in a busy session's inbox and records it answered, never stopping it", :aggregate_failures do
    started_run("a-busy", "working", status: "busy", **hooked("a-busy"))

    expect(answer("a-busy", "yes")).to include("answered_at")
    expect(File.read(File.join(inbox, "a-busy.md"))).to eq("yes")
    expect(touched?).to be(false)
  end

  it "leads the queued answer with its step" do
    started_run("a-step", "working", status: "busy", **hooked("a-step"))
    answer("a-step", "yes", "step.value=Read your review.")

    expect(File.read(File.join(inbox, "a-step.md"))).to eq("Read your review.\n\nyes")
  end

  it "refuses by name a busy session without the inbox hook, never stopping it", :aggregate_failures do
    started_run("a-unhooked", "working", status: "busy")

    expect(answer("a-unhooked", "yes")).to include("carries no inbox hook")
    expect(touched?).to be(false)
  end

  it "keeps a busy unhooked session's run waiting on a verdict, to be sent again", :aggregate_failures do
    started_run("a-verdict", "working", status: "busy")
    launch("agent_run.await!", "to=a-verdict", "--wait")
    answer("a-verdict", "sound", "verdict.value=j-1")

    expect(check("a-verdict")).to include("status" => "started", "reviewing" => true, "resuming" => false)
    expect(touched?).to be(false)
  end

  it "resumes a session listed idle whose job still reads working, since an idle one runs no hook", :aggregate_failures do
    started_run("a-idle", "working", status: "idle", **hooked("a-idle"))

    expect(answer("a-idle", "yes")).to include("answered_at")
    expect(File.exist?(File.join(inbox, "a-idle.md"))).to be(false)
    expect(File.read(resume_args)).to include("[pipeline answer] yes")
  end

  it "ends the run when a session whose answer was queued then reads stopped", :aggregate_failures do
    started_run("a-queued", "working", status: "busy", **hooked("a-queued"))
    answer("a-queued", "yes")
    sessions("stopped")

    expect(check("a-queued")).to include("status" => "finished", "condition" => "stopped", "resuming" => false)
  end

  it "resumes a working session with the answer as its prompt", :aggregate_failures do
    started_run("a-working", "working")

    expect(answer("a-working", "yes")).to include("answered_at")
    resumed = ["--bg", "--resume", "stand-in-session-0000-full", "--", "[pipeline answer] yes"]
    expect(File.read(resume_args).split("\n")).to eq(resumed)
  end

  it "refuses an answer that says nothing, and resumes nothing", :aggregate_failures do
    started_run("a-blank", "blocked")

    expect(answer("a-blank", "  ")).to include("says something")
    expect(File.exist?(resume_args)).to be(false)
  end

  it "resumes a blocked session with the answer as its prompt, and records when", :aggregate_failures do
    started_run("a-blocked", "blocked")

    out = JSON.parse(answer("a-blocked", "use the staging branch"))

    expect(out.dig("state", "answered_at")).not_to be_nil
    resumed = ["--bg", "--resume", "stand-in-session-0000-full", "--", "[pipeline answer] use the staging branch"]
    expect(File.read(resume_args).split("\n")).to eq(resumed)
  end

  def stopped = File.read(File.join(scratch, "stopped")).split("\n")

  it "stops a blocked session, wakes it in place, and keeps the run on the same session", :aggregate_failures do
    started_run("a-place", "blocked")
    state = JSON.parse(answer("a-place", "go on"))["state"]

    expect(stopped).to eq(["stand-in-session"])
    expect(state).to include("session" => "stand-in-session")
    expect(File.read(resume_args)).not_to include("--agent")
  end

  it "follows the copy the CLI started instead, so the run holds the new session", :aggregate_failures do
    File.write(File.join(scratch, "copy"), "yes")
    started_run("a-copy", "blocked")
    state = JSON.parse(answer("a-copy", "go on"))["state"]

    expect(state).to include("session" => "copy-session-1")
  end
end
