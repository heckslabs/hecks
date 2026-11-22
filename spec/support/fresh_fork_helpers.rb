# What the fresh-fork spec drives: a coder run whose job reads as its parent's copy, checked while
# the listing says one thing or another.
module FreshForkHelpers
  # Dispatches a coder, gives its job the parent's copy and its listing a status, checks it once.
  #
  # @param work [String] the Work item
  # @param listing [String, nil] the status the listing gives the session; nil lists nothing
  # @return [Integer] the SessionFinished events the check recorded
  def finishes_after_check(work, listing:)
    wait_as_coder(work)
    before = count("SessionFinished")
    list_and_check(work, { state: "done", detail: "starting…" }, listing)
    count("SessionFinished") - before
  end

  # Writes the job's state and the listing, then checks the run as a sweep would.
  #
  # @return [void]
  def list_and_check(work, job, listing)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(job))
    entries = listing ? [{ id: "stand-in-session", status: listing }] : []
    File.write(File.join(scratch, "sessions.json"), JSON.generate(entries))
    launch("agent_run.check!", "to=#{work}", "--wait")
  end
end
