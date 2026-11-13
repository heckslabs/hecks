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

  def waiting_coder(work) = coder_reading(work, "blocked")

  # A coder run whose session ended `done`, so the run reads finished.
  def finished_coder(work) = coder_reading(work, "done")

  # The session's listing and job are written before the dispatch, since the start reads the job.
  def coder_reading(work, state)
    listed = { id: "stand-in-session", sessionId: "stand-in-session-0000-full", state: state }
    File.write(File.join(scratch, "sessions.json"), JSON.generate([listed]))
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))
    launch("agent_run.dispatch!", "run.value=#{work}", "repo.value=#{scratch}", "brief.value=build it", "--wait")
    launch("agent_run.check!", "to=#{work}", "--wait")
  end

  def judge(run, work, role, word: nil)
    launch("agents", "Verdict.judge!", "run.value=#{run}", "work.value=#{work}", "role.value=#{role}",
           "answer.value=sound with changes", *("word.value=#{word}" if word), "--wait")
  end

  def verdicts(query) = launch("agents", "Verdict.#{query}").first.to_s

  def resumed_with = File.read(File.join(scratch, "resume.args")).split("\n").last

  # The whole prompt the session was woken with: every argument after `--`.
  def prompt = File.read(File.join(scratch, "resume.args")).split("\n--\n", 2).last.chomp

  %w[architect reviewer].each do |role|
    it "answers the waiting coder with a #{role}'s verdict and records it delivered", :aggregate_failures do
      waiting_coder("w-#{role}")
      judge("j-#{role}", "w-#{role}", role)

      expect(resumed_with).to eq("[pipeline answer] sound with changes")
      expect(verdicts("delivered")).to include("j-#{role}")
    end
  end

  # A verdict to build tells the coder its turn goes on: the review's read is a step, not the end.
  { "sound" => "build the Work item now", "changes" => "revise the plan as its findings say" }.each do |word, step|
    it "tells a coder whose verdict is #{word} to continue in this session", :aggregate_failures do
      waiting_coder("w-#{word}")
      judge("j-#{word}", "w-#{word}", "architect", word: word)

      expect(prompt).to start_with("[pipeline answer] ").and include("continue in this session", step)
      expect(prompt).to end_with("sound with changes")
    end
  end

  # What a rethink asks of the coder is its brief's, so the verdict goes to it as written.
  it "answers a rethink with the verdict alone" do
    waiting_coder("w-rethink")
    judge("j-rethink", "w-rethink", "architect", word: "rethink")

    expect(prompt).to eq("[pipeline answer] sound with changes")
  end

  # A Work item restarted after its coder finished keeps the finished run archived as `<work>~1`
  # beside the new one; the verdict reaches the new run and is not refused for the archived one.
  it "records a verdict delivered when a finished run of the Work item was archived", :aggregate_failures do
    finished_coder("w-restarted")
    waiting_coder("w-restarted")
    judge("j-restarted", "w-restarted", "architect")

    expect(verdicts("delivered")).to include("j-restarted")
    expect(verdicts("undelivered")).not_to include("j-restarted")
  end

  # A refused resume is retried, not settled; `agents_verdict_redelivery_spec.rb` follows it on.
  it "keeps a verdict to send again, with the reason, when the coder's session refuses the resume" do
    waiting_coder("w-refused")
    File.write(File.join(scratch, "refuse"), "yes")
    judge("j-refused", "w-refused", "architect")

    expect(verdicts("unresumed")).to include("j-refused")
  end
end
