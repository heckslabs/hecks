# frozen_string_literal: true

# A fixed board state for the text panel's specs: the shape `/api/state` serves, with the open
# train pull requests the snapshot adds.
module PipelineBoardPanelState
  def stages
    [{ name: "Work items", state: "working", count: "227/3/156", detail: "planned / started / done" },
     { name: "Sessions", state: "attention", count: "3", detail: "1 busy, 1 blocked on you, of 5 in the last day" },
     { name: "Local main", state: "attention", count: "4", detail: "4 ahead, 0 behind origin/main; clean" },
     { name: "Train", state: "ok", count: "abc123def", detail: "last push 0.5 h ago" },
     { name: "CI", state: "failed", count: "2", detail: "b2b2b2b failure, 5.0 min, 2 failed jobs" },
     { name: "Promote", state: "ok", count: "0", detail: "stable f475e003e; 0 commits behind main" },
     { name: "Release", state: "ok", count: "v7.1.0", detail: "published" }]
  end

  def metrics
    [{ id: "success", label: "CI success", value: 90, unit: "%", state: "ok", detail: "last 20 main runs",
       trend: { delta: 20.0, unit: "%", better: true } },
     { id: "wall", label: "Median CI wall", value: 4.2, unit: "min", state: "attention", detail: "goal 3 min",
       trend: { delta: -2.0, unit: "min", better: true } },
     { id: "red", label: "Main red for", value: nil, unit: "", state: "unknown", detail: "unknown: no runs", trend: nil }]
  end

  def ci_runs
    [{ sha: "a1a1a1a", status: "completed", conclusion: "success" },
     { sha: "b2b2b2b", status: "completed", conclusion: "failure" },
     { sha: "c3c3c3c", status: "in_progress", conclusion: "" },
     { sha: "d4d4d4d", status: "completed", conclusion: "skipped" }]
  end

  def sessions
    [{ name: "coder-one", run: "board-snapshot", agent: "coder", status: "busy", detail: "writing the panel" },
     { name: "planner-one", run: "", agent: "planner", status: "blocked", owner: true, detail: "which of two plans?" },
     { name: "old-one", run: "stall-watch", agent: "architect", status: "done", detail: "reviewed the plan" }]
  end

  def open_work
    %w[alpha bravo charlie].map { |slug| { slug: slug, status: "planned", title: "Title of #{slug}", area: [] } } +
      [{ slug: "delta", status: "started", title: "Under way", area: [] }]
  end

  def panel_state
    { generated_at: "2026-11-07T12:00:00Z", stages: stages, metrics: metrics, ci_runs: ci_runs, sessions: sessions,
      open_work: open_work, roles: [{ name: "coder", live: 1 }, { name: "planner", live: 0 }],
      reviews: [{ work: "alpha", verdict: "sound" }, { work: "bravo", verdict: "" }],
      recommendations: [{ change: "36f689057", reasons: "" }],
      train_prs: [{ number: 1272, branch: "train/main-5543822", total: 89, passed: 87, failed: 2, pending: 0 }],
      cycles: cycles }
  end

  def cycles
    { rank:   90,
      stats:  [{ stage: "implementing", items: 2, median: 789, percentile: 3720 }],
      cycles: [{ work: "busy", seconds: 1200, open: "planning", stages: [{ stage: "planning" }] },
               { work: "ci-observe", seconds: 1345, open: nil, stages: [{ stage: "implementing" }] }] }
  end
end
