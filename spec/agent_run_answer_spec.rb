require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# `AgentRun.Answer` through the booted Hecks domain: a blocked session is resumed with the answer,
# and anything else is refused. A stand-in `claude` records each `--resume` call, so no real
# session is resumed. The adapter's argument list and directory are in claude_agents_spec.rb.
RSpec.describe "AgentRun.Answer through the Agents port" do
  ANSWER_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "stop" ]; then echo "$2" >> "$here/stopped"; exit 0; fi
    if [ "$2" = "--resume" ]; then
      printf '%s\\n' "$@" > "$here/resume.args"; echo resumed >> "$here/resumes"
      printf 'backgrounded · resumed-session\\n'; exit 0
    fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
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
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0 })
    end)
  end

  # The session as `claude agents` lists it, and its job's state, both in `state`.
  def sessions(state)
    listing = [{ id: "stand-in-session", sessionId: "stand-in-full", state: state }]
    File.write(File.join(scratch, "sessions.json"), JSON.generate(listing))
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def started_run(run, state)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")
    sessions(state)
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def answer(run, text) = launch("agent_run.answer!", "to=#{run}", "answer.value=#{text}", "--wait").first.to_s

  it "refuses an answer to a session that is working, and resumes nothing", :aggregate_failures do
    started_run("a-working", "working")

    expect(answer("a-working", "yes")).to include("blocked on a person")
    expect(File.exist?(resume_args)).to be(false)
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
    expect(File.read(resume_args).split("\n")).to eq(["--bg", "--resume", "stand-in-full", "--", "use the staging branch"])
  end

  # The resumed job's own state, which the run follows once it holds the new session.
  def new_job(state)
    FileUtils.mkdir_p(File.join(scratch, "jobs", "resumed-session"))
    File.write(File.join(scratch, "jobs", "resumed-session", "state.json"), JSON.generate(state: state))
  end

  def run_state(run) = JSON.parse(launch("agent_run.check!", "to=#{run}", "--wait").first.to_s)["state"]

  it "follows the new job: the run holds its session, leaves blocked, and the old job is stopped", :aggregate_failures do
    started_run("a-follow", "blocked")
    state = JSON.parse(answer("a-follow", "go on"))["state"]

    expect(state).to include("session" => "resumed-session", "condition" => "working")
    expect(File.read(File.join(scratch, "stopped")).split("\n")).to eq(["stand-in-session"])
  end

  it "reads the new job on later checks, not the old one", :aggregate_failures do
    started_run("a-later", "blocked")
    answer("a-later", "go on")
    new_job("done")

    expect(run_state("a-later")).to include("session" => "resumed-session", "condition" => "done")
  end

  it "refuses a second answer while the resumed job works, and forks nothing more", :aggregate_failures do
    started_run("a-twice", "blocked")
    answer("a-twice", "first")

    expect(answer("a-twice", "second")).to include("blocked on a person")
    expect(File.read(File.join(scratch, "resumes")).split("\n").size).to eq(1)
  end
end
