"use strict";

// The staged bad day, in the shape of GET /api/state plus an `extras` object for the readings no
// query answers yet. Every value here is staged; none is read from the board.
//
// It is the same day as the instrument panel mock-up's, so the two can be compared number for
// number: the values are copied from that mock-up's staged.js at commit 75bf8886f of the branch
// board-mock-up-as-an-instrument-panel, and only the wording is the signal box's. A later change
// to that file is not followed here. Where that file leaves a reading empty (sessions, roles,
// events, the load curve) this one fills it to agree with the rest of the day.

// Today at a local clock time, as an ISO string.
function todayAt(clock) {
  const [hours, minutes] = clock.split(":").map(Number);
  const day = new Date();
  day.setHours(hours, minutes, 0, 0);
  return day.toISOString();
}

// A load curve for the day: calm until after noon, over the limit of 16 from 14:02, 21.4 at 15:10.
function stagedLoad() {
  const samples = [];
  for (let minute = 0; minute < 15 * 60 + 10; minute += 10) {
    const late = Math.max(0, minute - 12 * 60 - 40);
    const load = 9 + 2 * Math.sin(minute / 47) + late * 0.08;
    const clock = `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
    samples.push([todayAt(clock), Math.round(load * 10) / 10]);
  }
  return [...samples, [todayAt("15:10"), 21.4]];
}

const HELD_RED = "main is red, landings refuse";

// The work items in flight, by where they stand: [slug, title, why it is held].
const ADMITTED = [
  ["the-board-shows-the-compute-meter", "The board shows the compute meter", "no seat, load short"],
  ["trail-roles-from-bluebook", "Trail roles come from the bluebook", "no seat, load short"],
];
const RUNNING = [
  ["shape-ledger-live-store-change", "Shape ledger accepts a live-store change", "waits on the owner's approval"],
  ["two-migrations-rename-one-column", "Two migrations rename the same column", "waits on the orchestrator's answer"],
  ["board-stuck-reads-the-impediments-view", "Board stuck list reads the impediments view", ""],
  ["serve-verb-core", "Serve verb moves to core", ""],
  ["machine-readings-carry-their-time", "Machine readings carry their time", ""],
  ["train-ci-runs-are-recorded", "Train CI runs are recorded while the board is down", ""],
  ["feature-page-shows-and-switches-flags", "Feature page shows and switches flags", ""],
  ["reviewrequest-close-superseded", "Review requests close when superseded", ""],
  ["red-main-1871", "Revert the landing that broke main", ""],
];
const REVIEWED = [
  ["board-answer-reply-delivers", "Board answer reply delivers"],
  ["trail-query", "Trail query"],
  ["board-page-declaration", "Board page declaration"],
];
const LANDED = [
  ["a81f20c3d7", "Signalbox pressure is posted or says why"],
  ["09be7714aa", "Board lists search, sort and filter"],
  ["c2d94e01f5", "Unanswered help shows on the stuck list"],
  ["5f6071be92", "The train is a process manager"],
];

// The fill's held items: so many, each with one reason.
function heldItems(count, reason, slug) {
  return Array.from({ length: count }, (_, i) => ({ slug: `${slug}-${i + 1}`, reason }));
}

function stagedStages() {
  const stage = (name, count, state, detail, since) => ({ name, count, state, detail, since: todayAt(since) });
  return [
    stage("Overdue for you", "3", "failed", "3 questions past their mark", "09:30"),
    stage("Work items", "412/9/1046", "working", "planned / started / done", "15:10"),
    stage("Sessions", "9", "attention", "9 busy, 3 blocked on you, of 34 in the last day", "15:10"),
    stage("Signal", "Danger", "failed", "Danger: not admitting since 14:02, load short", "14:02"),
    stage("Fill", "0 of 5", "attention", "started none of 14 that could start", "15:09"),
    stage("Local main", "12", "attention", "12 ahead, 0 behind origin/main; clean; quick gate red", "13:41"),
    stage("Integration", "4", "failed", "4 landed and held, main is red; last advance 89 min ago", "13:41"),
    stage("Train", "0", "attention", "no train boards while main is red; last push 1.6 h ago", "13:36"),
    stage("CI", "3", "failed", "3 failed jobs on main's head; the revert is in CI since 15:04", "13:41"),
    stage("Promote", "0", "ok", "stable holds; nothing is promoted while main is red", "13:41"),
    stage("Release", "-", "unknown", "unknown: no v release found", "15:10"),
  ];
}

function stagedStuck() {
  const entry = (group, subject, what, waits_on, since, owner_run) =>
    ({ group, subject, what, waits_on, since: todayAt(since), kind: "staged", owner_run });
  return [
    entry("waiting on a person", "shape-ledger-live-store-change", "the live-store change to the shape ledger needs approval",
      "the owner", "11:20", "shape-ledger-live-store-change"),
    entry("waiting on a person", "two-migrations-rename-one-column", "asks which of two migrations renames the column",
      "the orchestrator", "13:05", "two-migrations-rename-one-column"),
    entry("waiting on a person", "release 7.4.0", "ready and holding for approval", "the owner", "09:30", "release-7-4-0"),
    entry("standing too long", "a reviewer's session", "no word for 96 min", "the orchestrator", "13:34",
      "3621f6e3efc10c06eb098fb08fcc80a823f57d6b"),
    entry("standing too long", "landing 762f05a364", "at verifying for 3.2 h", "the landing's coder", "11:58", "762f05a364"),
  ];
}

function stagedWork() {
  const started = [...ADMITTED, ...RUNNING].map(([slug, title, held]) => ({ slug, status: "started", title, held }));
  const planned = Array.from({ length: 412 }, (_, i) => ({ slug: `planned-${i}`, status: "planned", title: "" }));
  return [...started, ...planned];
}

function stagedSessions() {
  return RUNNING.map(([slug, , held]) => ({ name: slug, state: held ? "blocked" : "working", work_item: slug }));
}

function stagedRuns() {
  const landed = LANDED.map(([short, name]) => ({ short, name, stage: "verified", parked: false, held: HELD_RED }));
  const train = { short: "train-1862", name: "train 1862, three landings aboard", stage: "boarding", parked: false,
    held: "stopped at boarding, main is red" };
  return [...landed, train];
}

function stagedExtras() {
  const train = (clock, ok) => ({ at: todayAt(clock), ok, label: ok ? "train, green" : "train, red" });
  return {
    all: true,
    now: Date.parse(todayAt("15:10")),
    signal: {
      aspect: "danger",
      reading: "Danger: not admitting since 14:02, load short",
      more: "Load 21.4 against a limit of 16.0. Nothing is admitted until load falls below the limit; work in flight keeps running.",
    },
    episodes: [
      { from: todayAt("03:12"), to: todayAt("03:40"), ended: "fixed forward by a coder" },
      { from: todayAt("10:05"), to: todayAt("10:52"), ended: "reverted by the pipeline" },
      { from: todayAt("13:41"), to: null,
        ended: "being reverted: the third red episode today; revert 51d0aa37e4 in CI since 15:04, taken by red-main-1871" },
    ],
    admission: [
      { from: todayAt("10:05"), to: todayAt("10:58"), why: "main red" },
      { from: todayAt("14:02"), to: null, why: "load short" },
    ],
    reviewed: REVIEWED.map(([slug, title]) => ({ slug, title })),
    notes: { "on main": "31 today, before 13:41" },
    landings: ["00:31", "01:02", "01:40", "02:15", "02:58", "04:10", "04:44", "05:20", "06:03", "06:39", "07:12", "07:50",
      "08:14", "08:41", "09:05", "09:33", "11:20", "11:48", "12:09", "12:31", "12:55", "13:12", "13:30"].map(todayAt),
    trains: [train("01:10", true), train("03:05", false), train("05:30", true), train("08:20", true), train("09:58", false),
      train("12:15", true), train("13:36", false)],
  };
}

function badDay() {
  const metric = (label, value, unit, state, detail) => ({ label, value, unit, state, detail });
  return {
    generated_at: todayAt("15:10"),
    stale: false,
    stages: stagedStages(),
    board: { stuck: stagedStuck() },
    fanout: {
      rows: [],
      fill: {
        load: 21.4, limit: 16.0, cap: 5, started: 9, at: todayAt("15:09"), would_start: [],
        skipped: [
          ...heldItems(9, "admission is closed: load 21.4 is over the limit 16.0", "waiting-item"),
          ...heldItems(3, "it waits on a work item that has not landed", "blocked-item"),
          ...heldItems(2, "its area is held by a running item", "area-item"),
        ],
      },
    },
    open_work: stagedWork(),
    sessions: stagedSessions(),
    integration: { needs_human: 0, runs: stagedRuns() },
    ci_runs: [],
    metrics: [
      metric("Main red for", 1.5, "h", "failed", "since 13:41"),
      metric("CI success", 85, "%", "attention", "last 20 main runs"),
      metric("Load", 21.4, "of 16.0", "failed", "over the limit since 14:02"),
      metric("Median CI wall", 2.9, "min", "ok", "last 20 main runs"),
      metric("Work finished", 131, "items / 24 h", "ok", "today and yesterday"),
      metric("Disk free", 71.2, "GB", "ok", ""),
    ],
    roles: [
      { name: "orchestrator", live: 1, waiting: 0 },
      { name: "coder", live: 9, waiting: 2 },
      { name: "reviewer", live: 1, waiting: 0 },
    ],
    events: [
      { at: todayAt("15:04"), name: "RevertSentToCi", aggregate: "staged" },
      { at: todayAt("14:02"), name: "AdmissionClosed", aggregate: "staged" },
      { at: todayAt("13:41"), name: "RedFlagRaised", aggregate: "staged" },
    ],
    daily_health: { line: "pipeline health: 1 red episode open, 4 landings held behind it, 1 session silent for 96 min" },
    board_restarts: { notes: [] },
    load_history: { samples: stagedLoad(), limit: 16.0 },
    extras: stagedExtras(),
  };
}
