require_relative "stall_watch_looks"

# Tap lines of each impediment source, for the impediments group: an `[event, id, minutes ago,
# aggregate]` row each, with the line's links as a fifth element when it has any.
module ImpedimentLooks
  # A hold, a failed session, two run findings and a blocked session, none of them gone.
  STANDING = [
    ["BoardingHoldSettled", "hold-1", 15, "Hecks::BoardingHold"],
    ["SessionFailed", "work-a", 5, "Hecks::AgentRun"],
    ["RunFindingReported", "gate-quick-rubocop", 30, "Tickets::Finding"],
    ["RunFindingReported", "run-77", 10, "Tickets::Finding"],
    ["SessionBlocked", "stuck", 20, "Hecks::AgentRun"]
  ].freeze

  # The line that makes each standing source gone.
  GONE = {
    "a released hold"               => ["BoardingReleaseSettled", "release-9", 1, "Hecks::BoardingRelease"],
    "a failed run whose item moved" => ["WorkYielded", "work-a", 1, "Tickets::Work"],
    "an answered session"           => ["AgentRunAnswered", "stuck", 1, "Hecks::AgentRun"]
  }.freeze

  def write_sources(rows)
    lines = rows.each_with_index.map do |(event, id, ago, aggregate, links), seq|
      line(seq + 1, event, id, ago).merge(aggregate:, links: links || {})
    end
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def impediments = watching.impediments(run: "look-1")

  def kinds = impediments.map { |row| row[:stall_kind] }

  def row_of(kind) = impediments.find { |row| row[:stall_kind] == kind }

  def unclosed_kinds = watching.unclosed(run: "look-1").map { |row| row[:stall_kind] }
end
