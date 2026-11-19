require "fileutils"
require "json"
require "tmpdir"

# Coder runs in each state a verdict can find them in, on a Memory boot with a stand-in `claude`
# that refuses a `--resume` while a `refuse` file exists, so no real session is resumed. The group
# that includes the shared context names `@hecks`.
module AnswerRefusedLooks
  STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "stop" ]; then exit 0; fi
    if [ "$2" = "--resume" ] && [ -f "$here/refuse" ]; then echo "refused" >&2; exit 1; fi
    echo "backgrounded · stand-in-session"
  SH

  # @param argv [Array<String>] the launcher's arguments
  # @return [Array] the launcher's answer
  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  # Starts a coder run whose session reads `state`; the listing and job are written first, since
  # the start reads the job.
  # @param work [String] the Work item the run is keyed by
  # @param state [String] the job's state
  def coder_reading(work, state)
    listed = { id: "stand-in-session", sessionId: "stand-in-session-0000-full", state: state }
    File.write(File.join(scratch, "sessions.json"), JSON.generate([listed]))
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))
    launch("agent_run.dispatch!", "run.value=#{work}", "repo.value=#{scratch}", "brief.value=build it", "--wait")
    launch("agent_run.check!", "to=#{work}", "--wait")
  end

  # A coder run that finished and whose session was then removed.
  # @param work [String] the Work item the run is keyed by
  def tidied_coder(work)
    coder_reading(work, "done")
    tidy(work)
  end

  # @param work [String] the Work item the run is keyed by
  def tidy(work) = launch("agent_run.tidied!", "to=#{work}", "tidied_at.value=2026-11-15T01:46:00Z", "--wait")

  # @param run [String] the judge's run, which keys the verdict
  # @param work [String] the Work item the verdict is for
  # @param word [String] the verdict word
  def judge(run, work, word)
    launch("agents", "Verdict.judge!", "run.value=#{run}", "work.value=#{work}", "role.value=architect",
           "answer.value=sound with changes", "word.value=#{word}", "--wait")
  end

  # The verdict's resume is refused while the coder waits; the run then finishes (and the block
  # may tidy it), and the verdict is sent again.
  # @param run [String] the judge's run
  # @param work [String] the Work item
  def redelivered_after_the_end(run, work)
    coder_reading(work, "blocked")
    File.write(File.join(scratch, "refuse"), "yes")
    judge(run, work, "changes")
    launch("agent_run.finish!", "to=#{work}", "condition.value=done", "detail.value=gone", "checkout.value=", "--wait")
    yield if block_given?
    launch("agents", "Verdict.redeliver!", "to=#{run}", "work.value=#{work}", "answer.value=again",
           "word.value=changes", "--wait")
  end

  # @param query [String] a Verdict query
  # @return [String] its answer, as text
  def verdicts(query) = launch("agents", "Verdict.#{query}").first.to_s

  # @param event [String] an event name
  # @param work [String] the Work item the run is keyed by
  # @return [Array] the recorded events of that name about the run
  def recorded(event, work)
    @hecks.registry.event_log.select do |entry|
      text = entry.to_h.to_s
      entry.to_h.values.any? { |value| value.to_s.end_with?(event) } && text.include?(work)
    end
  end
end

RSpec.shared_context "with a stand-in claude for refused answers" do
  include AnswerRefusedLooks

  let(:scratch) { File.realpath(Dir.mktmpdir("answer-refused")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), AnswerRefusedLooks::STAND_IN)
    File.chmod(0o755, File.join(scratch, "claude"))
    ENV.update("PATH" => "#{scratch}:#{env["PATH"]}", "HOME" => scratch)
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
end
