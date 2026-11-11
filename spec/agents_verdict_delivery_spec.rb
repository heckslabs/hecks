require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# A judge's verdict reaches the coder waiting on its Work item with no PlanReview row at all:
# judged, it answers the coder's run in place, and the outcome is a delivered or an undeliverable
# verdict. A stand-in `claude` records each `--resume`, so no real session is resumed. Scratch
# state only.
RSpec.describe "the Agents verdict reaching the waiting coder" do
  VERDICT_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "stop" ]; then exit 0; fi
    if [ "$2" = "--resume" ] && [ -f "$here/refuse" ]; then echo "refused" >&2; exit 1; fi
    if [ "$2" = "--resume" ]; then printf '%s\\n' "$@" > "$here/resume.args"; echo "backgrounded · stand-in-session"; exit 0; fi
    echo "backgrounded · stand-in-session"
  SH

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:scratch) { File.realpath(Dir.mktmpdir("verdict-delivery")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), VERDICT_STAND_IN)
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

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def waiting_coder(work)
    launch("agent_run.dispatch!", "run.value=#{work}", "repo.value=#{scratch}", "brief.value=build it", "--wait")
    listed = { id: "stand-in-session", sessionId: "stand-in-session-0000-full", state: "blocked" }
    File.write(File.join(scratch, "sessions.json"), JSON.generate([listed]))
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "blocked"))
    launch("agent_run.check!", "to=#{work}", "--wait")
  end

  def judge(run, work, role)
    launch("agents", "Verdict.judge!", "run.value=#{run}", "work.value=#{work}", "role.value=#{role}",
           "answer.value=sound with changes", "--wait")
  end

  def verdicts(query) = launch("agents", "Verdict.#{query}").first.to_s

  def resumed_with = File.read(File.join(scratch, "resume.args")).split("\n").last

  %w[architect reviewer].each do |role|
    it "answers the waiting coder with a #{role}'s verdict and records it delivered", :aggregate_failures do
      waiting_coder("w-#{role}")
      judge("j-#{role}", "w-#{role}", role)

      expect(resumed_with).to eq("[pipeline answer] sound with changes")
      expect(verdicts("delivered")).to include("j-#{role}")
    end
  end

  it "records a verdict undeliverable, with the reason, when the coder's session refuses the resume" do
    waiting_coder("w-refused")
    File.write(File.join(scratch, "refuse"), "yes")
    judge("j-refused", "w-refused", "architect")

    expect(verdicts("undelivered")).to include("j-refused")
  end
end
