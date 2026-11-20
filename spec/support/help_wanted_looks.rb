require_relative "impediment_looks"
require_relative "stall_settled_looks"

# Calls for help over a throwaway tap: a hold fifteen minutes old is the impediment, a call is
# raised for it, and each look writes the HelpWanted events it emitted to the tap as the live
# tap would.
module HelpWantedLooks
  include ImpedimentLooks
  include StallSettledLooks

  HOLD = "stall-held-lock-hold-1".freeze
  FOLD = "stall-codebase-check-failed".freeze
  RELEASE = ["BoardingReleaseSettled", "release-9", "Hecks::BoardingRelease", 1].freeze

  def raise_help(impediment = HOLD, role = "orchestrator")
    result = with_tap { dispatch("Hecks::HelpWanted.Raise", **call_for(impediment, role)) }
    append("HelpWantedRaised", "help-#{impediment}", "Hecks::HelpWanted", 0)
    result
  end

  def call_for(impediment, role)
    { help: { value: "help-#{impediment}" }, opened_at: { value: "2026-11-20T10:00:00Z" }, waited: { value: 15 },
      holds_up: { value: "the push train" }, kind: { value: "release-dead-holder" },
      needs: { value: "Release the hold once its holder is confirmed dead." }, role: { value: role },
      cleared_by: { value: "help" } }
  end

  def assign(how, helper = "helper-1", impediment = HOLD)
    with_tap do
      dispatch("Hecks::HelpWanted.Assign", help: { value: "help-#{impediment}" }, helper: { value: helper },
                                           how: { value: how })
    end
  end

  # One beat: the look, then its HelpWanted closes written to the tap.
  def look(run)
    before = registry.event_log.size
    detect(run)
    closed = registry.event_log.drop(before).count { |event| event.name == "HelpWantedClosed" }
    closed.times { append("HelpWantedClosed", "help-#{HOLD}", "Hecks::HelpWanted", 0) }
  end

  def call(key = "help-#{HOLD}")
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("HelpWanted")).all.find { |row| row.id.to_s == key }
  end

  def read(query) = Hecks::Runtime::Dispatcher.new(registry).query("Hecks::HelpWanted.#{query}")

  def field(name, key = "help-#{HOLD}") = Hecks::Adapters::StartedWork.value(call(key), name)

  # The hold is released, so its impediment leaves the view.
  def release
    append(*RELEASE)
  end

  def relieved = watching.relieved(run: "look-1").map { |row| row[:help] }

  def a_started_run(run)
    with_tap { dispatch("Hecks::AgentRun.Dispatch", run: { value: run }, brief: "Wait.") }
    dispatch("Hecks::AgentRun.Begin", run: { value: run }, session: { value: "s-#{run}" })
  end
end
