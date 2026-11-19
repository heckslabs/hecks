require "json"

# What the run-result spec drives, beside {WakesCoderHelpers}: a coder run whose job is read once it
# closes, done, stopped or idle with its report said, and the `RunResult` row each closing leaves.
module RunResultHelpers
  # Each closing a coder's job can read, by name: the job's state, the closing report, and the
  # result code it records.
  CLOSINGS = {
    "a verified report"                      => ["done", "All green.\nResult: verified", "verified"],
    "a report whose specs were not run"      => ["done", "specs unchecked\nResult: unverified\nblocked", "unverified"],
    "a blocked report"                       => ["done", "Result: blocked\nblocked", "blocked"],
    "a bare stopped"                         => ["stopped", "stopped", "unstated"],
    "failing host tests with no result code" => ["done", "148 host test fails", "unstated"],
    "the closing word blocked alone"         => ["done", "blocked", "unstated"],
    "a report naming two codes"              => ["done", "Result: verified\nResult: blocked", "unstated"]
  }.freeze

  # The coder's job reads `state` with its closing report, and one check reads it.
  #
  # @param run [String] the run's key
  # @param state [String] the job's state
  # @param report [String] the coder's closing report
  # @return [void]
  def coder_closes(run, state, report)
    wait_as_coder(run)
    job(state: state, detail: report, output: { result: report })
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  # The coder said its report and went idle: the job still reads `working`, the listing `idle`.
  #
  # @param run [String] the run's key
  # @param report [String] the coder's closing report
  # @return [void]
  def coder_idles(run, report)
    wait_as_coder(run)
    idle(run, report)
  end

  # The coder asks for a plan review, then ends its turn to wait for the verdict.
  #
  # @param run [String] the run's key and its Work item
  # @return [void]
  def coder_waits_on_review(run)
    wait_as_coder(run)
    request_review(run)
    idle(run, "[review] waiting on the verdict")
  end

  # @param run [String] the run's key
  # @return [String, nil] the result code `RunResult.results` lists for the run
  def code_of(run)
    out, = launch("agents", "RunResult.results")
    row = JSON.parse(out.to_s[/\[.*\]/m] || "[]").find { |each| each["run"] == run }
    row && row["code"]
  end

  private

  def idle(run, report)
    job(state: "working", output: { result: report })
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", status: "idle" }]))
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def job(state)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
  end
end
