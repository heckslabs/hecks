"use strict";

// The staged bad day, in the shape of GET /api/state plus an `extras` object for the readings no
// query answers yet. It is the same day as the instrument panel mock-up's: main red with an
// episode being reverted, load short and admission closed, three entries waiting on a person and
// two standing too long. Every value here is staged; none is read from the board.

// Today at a local clock time, as an ISO string.
function todayAt(clock) {
  const [hours, minutes] = clock.split(":").map(Number);
  const day = new Date();
  day.setHours(hours, minutes, 0, 0);
  return day.toISOString();
}

// A load curve for the day: calm until early afternoon, then over the limit.
function stagedLoad() {
  const samples = [];
  for (let minute = 6 * 60; minute <= 14 * 60 + 40; minute += 10) {
    const late = Math.max(0, minute - 13 * 60 - 20);
    const load = 8 + 3 * Math.sin(minute / 47) + late * 0.16;
    const clock = `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
    samples.push([todayAt(clock), Math.round(load * 10) / 10]);
  }
  return samples;
}

function badDay() {
  const held = [
    ["red-episodes-are-stored", "admission closed: the signal is at danger"],
    ["board-answers-at-a-glance", "admission closed: the signal is at danger"],
    ["board-reads-today", "admission closed: the signal is at danger"],
    ["orchestrator-starts-from-the-glance", "admission closed: the signal is at danger"],
    ["orchestrator-hears-the-glance-change", "admission closed: the signal is at danger"],
    ["board-revamp-audit", "admission closed: the signal is at danger"],
    ["fill-names-its-reason-twice", "its area is held by signalbox-answers-the-board"],
    ["stage-strip-is-declared", "its area is held by measures-are-read-live"],
    ["trains-page-absorbs-ci", "waits on red-main-1871"],
  ];
  return {
    generated_at: todayAt("14:40"),
    stale: false,
    stages: [
      { name: "Overdue for you", state: "failed", count: "3", detail: "3 entries wait on a person; the oldest since 11:05", since: todayAt("11:05") },
      { name: "Work items", state: "working", count: "412/5/1021", detail: "planned / started / done", since: todayAt("14:38") },
      { name: "Sessions", state: "attention", count: "4", detail: "4 busy, 1 blocked on a question, of 29 in the last day", since: todayAt("14:36") },
      { name: "Signal", state: "failed", count: "danger", detail: "Danger: not admitting since 14:02, load short", since: todayAt("14:02") },
      { name: "Fill", state: "attention", count: "4 of 5", detail: "would start 0, held 9; admission closed", since: todayAt("14:39") },
      { name: "Local main", state: "failed", count: "4", detail: "main is red: flag 1871; 4 commits ahead of origin/main; clean", since: todayAt("13:41") },
      { name: "Integration", state: "failed", count: "2", detail: "1 held by the red flag, 1 parked for a person", since: todayAt("13:41") },
      { name: "Train", state: "attention", count: "1", detail: "the revert of 7c1d9e4 boarded at 14:31; nothing else boards while main is red", since: todayAt("14:31") },
      { name: "CI", state: "failed", count: "2", detail: "a41c9e2 failure, 3.1 min, 2 failed jobs: rspec_impl, checks_static", since: todayAt("13:41") },
      { name: "Promote", state: "ok", count: "4", detail: "stable 9e563f13a; 4 commits behind main", since: todayAt("11:52") },
      { name: "Release", state: "attention", count: "7.4.0", detail: "7.4.0 is ready and holds for approval", since: todayAt("10:20") },
    ],
    board: {
      stuck: [
        { group: "waiting on a person", subject: "landing of fill-names-its-reason", what: "refused twice; needs a pick between two branches", waits_on: "Chris (owner)", since: todayAt("11:05"), kind: "landing_refused", owner_run: "b7d02f61aa41c9e2b7d02f61aa41c9e2b7d02f61" },
        { group: "waiting on a person", subject: "release 7.4.0", what: "ready and holding for approval", waits_on: "Chris (owner)", since: todayAt("10:20"), kind: "release_hold", owner_run: "release-7.4.0" },
        { group: "waiting on a person", subject: "signalbox-answers-the-board", what: "asks which of two readings wins", waits_on: "Meredith (lead)", since: todayAt("13:12"), kind: "question", owner_run: "5c0e9d17-2a44-4f0b-9b1e-0f6a3d2c7e11" },
        { group: "standing too long", subject: "coder on stall-train-signals", what: "no word for 212 min", waits_on: "", since: todayAt("11:08"), kind: "stalled_session", owner_run: "3621f6e3efc10c06eb098fb08fcc80a823f57d6b" },
        { group: "standing too long", subject: "landing 4e1b7a2c90", what: "at verifying for 3.1 h", waits_on: "", since: todayAt("11:34"), kind: "slow_verification", owner_run: "4e1b7a2c90d14f6ab7d02f61aa41c9e2b7d02f61" },
      ],
    },
    fanout: {
      rows: [
        { slug: "red-main-1871", status: "started", sessions: ["9f2c11aa"], flags: [] },
        { slug: "signalbox-answers-the-board", status: "started", sessions: ["5c0e9d17"], flags: [] },
        { slug: "measures-are-read-live", status: "started", sessions: ["71b3e0c2"], flags: [] },
        { slug: "glance-reads-are-a-measure", status: "started", sessions: ["d04a6f19"], flags: [] },
        { slug: "red-episodes-are-recorded-whole", status: "started", sessions: [], flags: [] },
      ],
      fill: {
        load: 21.4, limit: 16.0, cap: 5, started: 4, at: todayAt("14:39"), would_start: [],
        skipped: held.map(([slug, reason]) => ({ slug, reason })),
      },
    },
    open_work: [
      { slug: "red-main-1871", status: "started", title: "Main is red: revert 7c1d9e4 and reopen its work item" },
      { slug: "signalbox-answers-the-board", status: "started", title: "Signalbox's signal is a reading on the board", held: "blocked on a question for Meredith (lead)" },
      { slug: "measures-are-read-live", status: "started", title: "Each measure is read live, not from a stored row" },
      { slug: "glance-reads-are-a-measure", status: "started", title: "Reads of the glance query are counted as a measure" },
      { slug: "red-episodes-are-recorded-whole", status: "started", title: "A red episode is recorded from first red to green", held: "admitted at 13:58; no seat while load is short" },
      ...Array.from({ length: 412 }, (_, i) => ({ slug: `planned-${i}`, status: "planned", title: "" })),
    ],
    sessions: [
      { name: "red-main-1871-revert", state: "working", work_item: "red-main-1871" },
      { name: "signalbox-answers-the-board", state: "blocked", work_item: "signalbox-answers-the-board" },
      { name: "measures-are-read-live", state: "working", work_item: "measures-are-read-live" },
      { name: "glance-reads-are-a-measure", state: "working", work_item: "glance-reads-are-a-measure" },
    ],
    integration: {
      needs_human: 1,
      runs: [
        { short: "4e1b7a2c90", name: "stall-train-signals", stage: "verifying", at: todayAt("11:34"), parked: false, held: "main is red: flag 1871" },
        { short: "b7d02f61aa", name: "fill-names-its-reason", stage: "needs_human", at: todayAt("11:05"), parked: true, held: "refused twice; waits on Chris (owner)" },
        { short: "c93d5510ef", name: "revert of 7c1d9e4", stage: "ci_running", at: todayAt("14:31"), parked: false },
        { short: "9e563f13a0", name: "board-fill-reading-is-current", stage: "green", at: todayAt("11:52"), parked: false },
      ],
    },
    ci_runs: [
      { sha: "5d2a0b7", started: todayAt("08:58"), conclusion: "success", event: "push", failed_jobs: 0, wall_minutes: 2.6 },
      { sha: "e07f3c1", started: todayAt("09:12"), conclusion: "failure", event: "push", failed_jobs: 1, wall_minutes: 2.9 },
      { sha: "1b8c44d", started: todayAt("09:47"), conclusion: "success", event: "push", failed_jobs: 0, wall_minutes: 2.7 },
      { sha: "9e563f1", started: todayAt("11:52"), conclusion: "success", event: "push", failed_jobs: 0, wall_minutes: 2.5 },
      { sha: "a41c9e2", started: todayAt("13:41"), conclusion: "failure", event: "push", failed_jobs: 2, wall_minutes: 3.1 },
    ],
    metrics: [
      { label: "CI success", value: 90, unit: "%", state: "attention", detail: "last 20 main runs" },
      { label: "Main red for", value: 1.0, unit: "h", state: "failed", detail: "since 13:41" },
      { label: "Commits not pushed", value: 4, unit: "commits", state: "attention", detail: "held behind the red flag" },
      { label: "Dispatched sessions", value: 4, unit: "of 5", state: "ok", detail: "" },
      { label: "Work finished", value: 96, unit: "items / 24 h", state: "ok", detail: "" },
    ],
    roles: [
      { name: "orchestrator", live: 1, waiting: 0 },
      { name: "coder", live: 3, waiting: 1 },
      { name: "reviewer", live: 0, waiting: 0 },
    ],
    events: [
      { at: todayAt("14:31"), name: "TrainBoarded", aggregate: "Hecks::SendTrain" },
      { at: todayAt("14:02"), name: "AdmissionClosed", aggregate: "Hecks::Signalbox" },
      { at: todayAt("13:43"), name: "RedFlagRaised", aggregate: "Hecks::RedFlag" },
    ],
    daily_health: { line: "pipeline health: 1 red episode open, 1 landing refused twice, 1 session silent for 212 min" },
    board_restarts: { notes: [] },
    load_history: { samples: stagedLoad(), limit: 16.0 },
    extras: {
      all: true,
      now: Date.parse(todayAt("14:40")),
      signal: {
        aspect: "danger",
        reading: "Danger: not admitting since 14:02, load short",
        more: "Load 21.4 against a limit of 16.0. Nothing is admitted until load falls below the limit; work in flight keeps running.",
      },
      episodes: [
        { from: todayAt("09:12"), to: todayAt("09:47"), ended: "fixed forward by 1b8c44d in 35 min" },
        { from: todayAt("13:41"), to: null, ended: "being reverted: the revert of 7c1d9e4 boarded at 14:31" },
      ],
      admission: [
        { from: todayAt("09:12"), to: todayAt("09:50"), why: "main red" },
        { from: todayAt("14:02"), to: null, why: "load short" },
      ],
      reviewed: [{ slug: "board-pages-render-to-images", title: "Every board page renders to an image" }],
      landings: ["07:41", "08:20", "08:52", "09:58", "10:31", "11:05", "11:34", "12:16", "12:57", "13:22"].map(todayAt),
      trains: [
        { at: todayAt("08:58"), ok: true, label: "5d2a0b7" },
        { at: todayAt("09:12"), ok: false, label: "e07f3c1" },
        { at: todayAt("09:47"), ok: true, label: "1b8c44d" },
        { at: todayAt("11:52"), ok: true, label: "9e563f1" },
        { at: todayAt("13:41"), ok: false, label: "a41c9e2" },
        { at: todayAt("14:31"), ok: null, label: "c93d551, the revert" },
      ],
    },
  };
}
