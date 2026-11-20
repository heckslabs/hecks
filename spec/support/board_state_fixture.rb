# frozen_string_literal: true

# A small board state as `PipelineStages#state` holds it, and the verdicts the bluebook's rows
# give for a set of measures, for the specs of the typed read model.
module BoardStateFixture
  AT = "2026-11-20T10:00:00Z"

  SESSIONS = [
    { id: "s1", run: "r1", status: "blocked", owner: true, detail: "[owner] push main?", started: AT, state: "blocked" },
    { id: "s2", run: "r2", status: "busy", idle_seconds: 1200, works_as: "coder", work_item: "w", state: "working" },
    { id: "s3", run: "", status: "busy", idle_seconds: 5 }
  ].freeze

  STAGES = [{ name: "Red flag", state: "failed", count: "f1", detail: "main is red" },
            { name: "Release", state: "ok", count: "v7.0.0", detail: "published" }].freeze

  METRICS = [
    { id: "release", label: "Latest release", value: 3, unit: "days ago", state: "ok", detail: "v7.0.0" },
    { id: "disk", label: "Disk free", value: nil, unit: "", state: "unknown", detail: "unknown: df failed" }
  ].freeze

  EVENTS = [{ at: AT, aggregate: "Tickets::Work", id: "w", name: "WorkFinished",
              reactions: [{ policy: "CloseWhenDone" }] }].freeze

  PULL = { number: 7, branch: "train/main-7", passed: 3, failed: 0, pending: 1 }.freeze

  # Each `Verdict` stage that replaced an adapter's own rule: the measures read, and the state.
  VERDICTS = [
    ["Disk free", { free_gb: 5 }, "failed"], ["Disk free", { free_gb: 20 }, "attention"],
    ["Disk free", { free_gb: 21 }, "ok"], ["Disk free", { free_gb: nil }, "unknown"],
    ["Boot hours", { share: 100 }, "failed"], ["Boot hours", { share: 80 }, "attention"],
    ["Boot hours", { share: 79 }, "ok"], ["Boot hours", { share: nil }, "ok"],
    ["Read", { value: 4.0 }, "ok"], ["Read", { value: nil }, "unknown"],
    ["Session idle", { idle_seconds: 901 }, "attention"], ["Session idle", { idle_seconds: 900 }, "working"],
    ["Train PR", { red: 1, pending: 2 }, "failed"], ["Train PR", { red: 0, pending: 2 }, "working"],
    ["Signal", { short: nil }, "unknown"], ["Signal", { short: 1 }, "attention"], ["Signal", { short: 0 }, "ok"],
    ["Fill", { headroom: nil }, "unknown"], ["Fill", { headroom: 0 }, "attention"], ["Fill", { headroom: 2 }, "ok"],
    ["Train PR", { red: 0, pending: 0 }, "ok"], ["Role", { live: 2 }, "working"], ["Role", { live: 0 }, "ok"]
  ].freeze

  # @return [Hash] the state: two stages, two tiles, three sessions, one role and one event
  def self.state
    { generated_at: AT, sessions: SESSIONS, stages: STAGES, metrics: METRICS, events: EVENTS,
      roles: [{ name: "coder", live: 1, working: [{ name: "r2" }] }] }
  end
end
