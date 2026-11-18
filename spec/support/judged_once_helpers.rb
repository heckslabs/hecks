# What the judged-once spec drives: an architect whose verdict is said while its job stands
# blocked in an idle session, read again at each check, and the events and runs that leaves.
module JudgedOnceHelpers
  # The number of events of one name the runtime has recorded.
  #
  # @param name [String] the event name
  # @return [Integer]
  def count(name) = @hecks.registry.event_log.map(&:name).count(name)

  # The number of readings of an architect's job the runtime has recorded.
  #
  # @return [Integer]
  def architect_reads
    @hecks.registry.event_log.count { |event| event.name == "JobRead" && event.payload.to_s.include?("architect") }
  end

  # Whether an architect's run is still listed started.
  #
  # @return [Boolean]
  def architect_running?
    out, = launch("agent_run.running")
    out.to_s.include?("\"agent\": \"architect\"")
  end

  # The architect stands blocked with its verdict said, in an idle session, which no other reading
  # of the job ends, and one check reads it, as a sweep would.
  #
  # @param work [String] the Work item under review
  # @return [void]
  def idle_architect_checked(work)
    wait_as_coder(work)
    request_review(work)
    state = { state: "blocked", output: { result: "Verdict: sound. Build it." } }
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", status: "idle" }]))
    launch("agent_run.check!", "to=r-#{work}", "--wait")
  end

  # A sweep's check of every run still started, as each beat makes.
  #
  # @return [void]
  def sweep = launch("agent_run.check_all!", "--wait")
end
