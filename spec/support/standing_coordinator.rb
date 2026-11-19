# frozen_string_literal: true

require_relative "resting_pruner"

# The helpers the standing-seat examples share: a sweep of the sessions, the stand-in session's
# job state, the orchestrator runs started, and the seat as `Coordinator.standing` reads it.
module StandingCoordinatorHelpers
  # One sweep of the sessions, keyed as a beat keys it. A sweep answers non-zero when any reaction
  # it meets refuses (a tidy, a reap), so its status is not the seat's.
  # @param beat [String] the sweep's key, which keys the run it starts
  # @return [Array] the launcher's text and status
  def sweep(beat) = launch("SessionSweep.check_all!", "run.value=#{beat}", "--wait")

  # Sets the state the stand-in session's job reads.
  # @param state [String] working, stopped, failed or done
  # @return [Integer] the bytes written
  def job_reads(state)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))
  end

  # The seat's run stops at the second sweep and the session works again by the third.
  # @return [Array] the third sweep's text and status
  def stop_and_refill
    job_reads("stopped")
    sweep("beat-2")
    job_reads("working")
    sweep("beat-3")
  end

  # A sweep as a launcher call of its own sees it: the seat is kept in Memory, so each process
  # opens it afresh, while the AgentRun journal is the one every process shares.
  # @param beat [String] the sweep's key
  # @return [Array] the launcher's text and status
  def fresh_sweep(beat)
    aggregate = @hecks.registry.bluebook("Agents").aggregate("Coordinator")
    @hecks.registry.repository("Agents", aggregate).reset!
    sweep(beat)
  end

  # The seat's run stops at the second fresh sweep and the session works again by the third.
  # @return [Array] the third sweep's text and status
  def fresh_stop_and_refill
    job_reads("stopped")
    fresh_sweep("beat-2")
    job_reads("working")
    fresh_sweep("beat-3")
  end

  # @return [Integer] how many seat starts the wakes delivered, refused ones included
  def coordinators_started = reactions("StartTheStandingSeatWhenWoken").size

  # @return [Array<Hash>] the seat's runs not yet ended, as `AgentRun.running` reads them
  def live_seats
    text, = launch!("AgentRun.running")
    Array(JSON.parse(text[/\[.*\]/m] || "[]")).select { |row| row["works_as"] == "orchestrator-seat" }
  end

  # @return [Hash, nil] the orchestrator's seat, or nil when none is open
  def seat
    text, = launch!("agents", "Coordinator.standing")
    Array(JSON.parse(text[/\[.*\]/m] || "[]")).first
  end
end

# A stand-in `claude` and a scratch journal, so no real orchestrator starts.
RSpec.shared_context "with a standing coordinator seat" do
  include_context "with a resting pruner"
  include StandingCoordinatorHelpers
end
