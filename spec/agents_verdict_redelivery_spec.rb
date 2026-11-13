require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# The sequence of 2026-11-13, 15:04 to 15:06Z, replayed on a Memory boot: a coder asks for a plan
# review and goes idle, the verdict is recorded, and the first resume is refused because the
# `claude` that resumes it cannot be run. The coder's run keeps waiting, so its idle job does not
# end it; the next sweep sends the verdict again and the second resume wakes the coder. A verdict
# refused on every try finishes the coder's run `unanswered`. A stand-in `claude` refuses while a
# `refuse` file exists, so no real session is resumed. Scratch state only.
RSpec.describe "a verdict the waiting coder's session refused" do
  REDELIVERY_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "stop" ]; then exit 0; fi
    if [ "$2" = "--resume" ] && [ -f "$here/refuse" ]; then echo "claude could not list sessions" >&2; exit 1; fi
    if [ "$2" = "--resume" ]; then printf '%s\\n' "$@" > "$here/resume.args"; echo "backgrounded · stand-in-session"; exit 0; fi
    echo "backgrounded · stand-in-session"
  SH

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:scratch) { File.realpath(Dir.mktmpdir("verdict-redelivery")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), REDELIVERY_STAND_IN)
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

  # The session's listing and job, as `claude agents` and the job's state file give them.
  def session(state, status: "busy", detail: "")
    listed = { id: "stand-in-session", sessionId: "stand-in-session-0000-full", state: state, status: status }
    File.write(File.join(scratch, "sessions.json"), JSON.generate([listed]))
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state, detail: detail))
  end

  # A coder run working on the Work item, which then asks for a plan review and waits.
  def waiting_coder(work)
    session("working")
    launch("agent_run.dispatch!", "run.value=#{work}", "repo.value=#{scratch}", "brief.value=build it", "--wait")
    launch("agent_run.check!", "to=#{work}", "--wait")
    launch("agent_run.await!", "to=#{work}", "--wait")
  end

  # The verdict is recorded while the coder's session refuses the resume.
  def refused_verdict(run, work)
    waiting_coder(work)
    File.write(File.join(scratch, "refuse"), "yes")
    launch("agents", "Verdict.judge!", "run.value=#{run}", "work.value=#{work}", "role.value=architect",
           "answer.value=sound with changes", "word.value=changes", "--wait")
  end

  # The coder's turn is over and it waits: idle in the listing, its job still working.
  def coder_idles(work)
    session("working", status: "idle", detail: "Sending my plan to the architect now.")
    launch("agent_run.check!", "to=#{work}", "--wait")
  end

  def sweep = launch("agent_run.check_all!", "--wait")

  def sweep_once_the_session_takes_it
    FileUtils.rm_f(File.join(scratch, "refuse"))
    sweep
  end

  def verdicts(query) = launch("agents", "Verdict.#{query}").first.to_s

  def run_of(work) = @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("AgentRun")).find(work)

  def status_of(work) = plain(run_of(work)[:status])

  def plain(value) = (value.respond_to?(:value) ? value.value : value).to_s

  it "keeps the verdict to send again and the coder's run waiting when the first resume is refused", :aggregate_failures do
    refused_verdict("j-first", "w-first")
    coder_idles("w-first")

    expect(verdicts("unresumed")).to include("j-first")
    expect(verdicts("undelivered")).not_to include("j-first")
    expect(status_of("w-first")).to eq("started")
  end

  it "resumes the waiting coder with the verdict on the next sweep", :aggregate_failures do
    refused_verdict("j-second", "w-second")
    coder_idles("w-second")
    sweep_once_the_session_takes_it

    expect(verdicts("delivered")).to include("j-second")
    expect(File.read(File.join(scratch, "resume.args"))).to include("sound with changes")
  end

  it "finishes the coder's run unanswered once the verdict was refused on every try", :aggregate_failures do
    refused_verdict("j-spent", "w-spent")
    4.times { sweep }

    expect(verdicts("undelivered")).to include("j-spent")
    expect(%i[status condition].map { |name| plain(run_of("w-spent")[name]) }).to eq(%w[finished unanswered])
  end
end
