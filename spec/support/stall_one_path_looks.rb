require_relative "help_wanted_looks"
require "hecks/hecks/adapters/stall_watching/clearing"

# One stall of each path on one tap: a blocked run, which its stall item clears, and a held
# lock, which a call for help clears.
module StallOnePathLooks
  include HelpWantedLooks

  BLOCK = "stall-agent-run-blocked-stuck".freeze
  SOURCES = [
    ["SessionBlocked", "stuck", 20, "Hecks::AgentRun"],
    ["BoardingHoldSettled", "hold-1", 15, "Hecks::BoardingHold"]
  ].freeze

  # @return [Array<Hash>] every `StallKind` row the Hecks bluebook declares
  def stall_kinds
    rows = registry.bluebook("Hecks").aggregate("StallWatch").value_objects.find { |object| object.hecks_name == "StallKind" }
    rows.members.map { |row| row.to_h.transform_keys(&:to_sym) }
  end

  def clearings = stall_kinds.map { |row| Hecks::Adapters::StallWatching::Clearing.of(row) }.uniq.sort

  def paths = impediments.to_h { |row| [row[:stall_kind], row[:cleared_by]] }

  # One beat, with the stalls it filed written to the tap as the live tap would.
  def look_and_tap(run)
    detect(run)
    keys("Hecks", "Stall", :stall).each { |stall| append("StallFiled", stall, "Hecks::Stall", 0) }
  end

  def raise_help_as(impediment, cleared_by)
    with_tap { dispatch("Hecks::HelpWanted.Raise", **call_for(impediment, "orchestrator"), cleared_by: { value: cleared_by }) }
  end

  # For each impediment, how many of its two paths it holds: a filed stall item, a standing call.
  def paths_held
    impediments.map { |row| [row[:filed] != "", !call("help-#{row[:impediment]}").nil?].count(true) }
  end

  def relieved_rows = watching.relieved(run: "look-2").map { |row| row.slice(:help, :reason) }
end
