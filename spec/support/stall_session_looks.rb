require_relative "stall_settled_looks"

# Beats over a throwaway tap that count the stall sessions they wake: each beat is a process of its
# own, whose Stall store starts empty, and each stall it filed or abandoned is written to the tap.
module StallSessionLooks
  include StallSettledLooks

  def look(run)
    stalls = registry.repository("Hecks", registry.bluebook("Hecks").aggregate("Stall"))
    before = registry.event_log.size
    stalls.reset!
    detect(run)
    tap_stalls(registry.event_log.drop(before).map(&:name))
  end

  def tap_stalls(names)
    keys("Hecks", "Stall", :stall).each do |stall|
      %w[StallFiled StallAbandoned].each { |event| append(event, stall, "Hecks::Stall", 0) if names.include?(event) }
    end
  end

  def sessions = events_named("AgentRunRequested")

  def blocked(run, started_ago = 30)
    append("AgentRunStarted", run, "Hecks::AgentRun", started_ago)
    append("SessionBlocked", run, "Hecks::AgentRun", 20)
  end

  # A run seated to answer the question `asks` asked, then blocked itself.
  def blocked_answerer(run, asks)
    append("QuestionSeated", asks, "Hecks::Question", 31)
    append("AgentRunRequested", run, "Hecks::AgentRun", 31, { work: asks })
    blocked(run)
  end

  # The detail of the one sighting of a run's blocked line.
  def blocked_detail(run)
    watching.unclosed(run: "look").find { |row| row[:stall] == "stall-agent-run-blocked-#{run}" }&.dig(:detail).to_s
  end

  # A blocked run's stall filed and its session begun, then its work item done, then a beat.
  def file_begin_then_settle(run)
    blocked(run)
    look("look-1")
    dispatch("Hecks::AgentRun.Begin", run: { value: "stall-agent-run-blocked-#{run}" }, session: { value: "s-1" })
    append("WorkFinished", run, "Tickets::Work", 0)
    look("look-2")
  end
end
