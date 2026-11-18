require_relative "stall_watch_looks"

# Tap lines and reads for the settled-subjects groups.
module StallSettledLooks
  def append(event, id, aggregate, minutes_ago, links = {})
    FileUtils.touch(tap)
    entry = line(File.readlines(tap).size + 1, event, id, minutes_ago).merge(aggregate: aggregate, links: links)
    File.open(tap, "a") { |file| file.puts(JSON.generate(entry)) }
  end

  def carry(id, branch, minutes_ago = 40, event = "CarryRequested")
    append(event, id, "Delivery::Landing", minutes_ago, { branch: branch })
  end

  def started(run) = append("AgentRunStarted", run, "Hecks::AgentRun", 300)

  def stalls = watching.unclosed(run: "look").map { |row| row[:stall] }

  def file_about_a_stall_item
    detect("look-0")
    with_tap do
      dispatch("Hecks::Stall.File", watch: "look-0", stall: { value: "stall-load-stall-x" }, kind: { value: "load" },
                                    subject: { value: "stall-x" }, opened_at: { value: "t" }, waited: { value: 9 },
                                    minutes: { value: 5 }, forgets: { value: 60 }, fixer: { value: "orchestrator" },
                                    title: { value: "t" }, detail: { value: "d" })
    end
  end

  def work_status(work)
    record = registry.repository("Tickets", registry.bluebook("Tickets").aggregate("Work")).all
                     .find { |row| Hecks::Adapters::StartedWork.value(row, :work).to_s == work }
    record && Hecks::Adapters::StartedWork.value(record, :status).to_s
  end

  # A run stalled, its stall filed and planned, then its work item done; each look is a beat of
  # its own, whose Stall store starts empty.
  def file_then_finish(run)
    started(run)
    detect("look-1")
    append("StallFiled", "stall-agent-run-session-#{run}", "Hecks::Stall", 1)
    append("WorkFinished", run, "Tickets::Work", 0)
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("Stall")).reset!
    detect("look-2")
  end
end
