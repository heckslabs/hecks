# frozen_string_literal: true

# Helpers for the specs that read `TurnFinished` from a scratch event log.
module TurnLogHelpers
  def stuck_item = { kind: "session", what: "stray orchestrator session", since: "65f4f4a9", owner_run: "fix-1", link: "" }

  def turn_line(run, at, verdict, extra = {})
    payload = { role: "orchestrator", verdict: verdict }.merge(extra)
    row = { kind: "event", at: at, aggregate: "Hecks::Agents::Turn", id: run, event: "TurnFinished", payload: payload }
    "#{JSON.generate(row)}\n"
  end

  def journal_over(*lines)
    File.write(log, lines.join)
    Hecks::Adapters::PipelineJournal.new(settings: { trace: ->(*) { { events: [] } }, tap: log, ttl: 0 })
  end

  def full_turn
    turn_line("orch-1", "2026-11-08T00:41Z", "routed",
              landed: [{ sha: "399811d02aa", title: "recognise a squash-carried train" }],
              main: { origin: "882b14eb4ff", ahead: 9, behind: 0, clean: true, origin_pushed_h: 0.6 },
              train: { open: nil, next_board: "after step-2 fixes" }, stuck: [stuck_item])
  end
end
