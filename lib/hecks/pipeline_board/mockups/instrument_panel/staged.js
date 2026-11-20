// Staged readings for the instrument-panel mock-up. Nothing in this file is read from the board.
//
// `unanswered` holds the readings no query answers yet; the real view shows them marked "staged".
// `badDay` is a whole staged state: the strip, the stuck list and the fill in the shape of
// GET /api/state, and the line and the day as the panel draws them.
window.STAGED = (function () {
  "use strict";

  // A time today, local, as an ISO string.
  function at(hm) {
    const d = new Date();
    const [h, m] = hm.split(":");
    d.setHours(Number(h), Number(m), 0, 0);
    return d.toISOString();
  }

  const item = (title, id, held) => ({ title, id, held: held || "" });

  const unanswered = {
    line: {
      admitted: [item("Waits-on refuses unknown keys", "waits-on-refuses-unknown-keys")],
      reviewed: [
        item("The planner cuts the next item while a seat waits", "the-planner-cuts-the-next-item-while-a-seat-waits"),
        item("A stalled fill raises its reason", "a-stalled-fill-raises-its-reason"),
      ],
    },
    closed: [
      { from: at("02:10"), to: at("02:42"), why: "load short" },
      { from: at("09:20"), to: at("09:47"), why: "load short" },
    ],
    landings: ["00:24", "01:05", "01:51", "03:02", "03:40", "04:28", "05:16", "06:01", "06:47", "07:30", "08:12",
      "08:55", "10:04", "10:41", "11:19", "12:07", "12:50", "13:33", "14:20", "15:08", "16:02", "17:15", "18:30",
      "19:44", "21:05", "22:20", "23:10"].map(at),
  };

  const stage = (key, label, value, state, note, unit) => ({
    key, label, value, state, note, unit: unit || "", source: "staged", fresh_at: at("15:10"),
  });

  const stuck = (group, what, waits_on, since, owner_run) => ({
    kind: "staged", group, what, waits_on, since: at(since), owner_run, link: "/runs/" + owner_run,
  });

  const skipped = (count, reason, slug) =>
    Array.from({ length: count }, (_, i) => ({ slug: slug + "-" + (i + 1), reason }));

  const metric = (label, value, unit, state, detail) => ({ id: label, label, value, unit, state, detail });

  const HELD_RED = "main is red, landings refuse";

  const badDay = {
    generated_at: at("15:10"),
    staged: {
      now: at("15:10"),
      red_main: {
        since: at("13:41"),
        line: "The third red episode today. The pipeline is reverting the landing that broke it; " +
          "landings and trains refuse until CI on main is green.",
        more: {
          "Episode": "red-episode-0f3a91c2",
          "Broken by": "landing 7c41e09b2a of 'Boarding rules become givens'",
          "Failed job": "rspec_ruby (shard b), spec/send_train_boarding_spec.rb",
          "Revert": "commit 51d0aa37e4, in CI since 15:04",
          "Taken by": "coder run red-main-1871",
        },
      },
      line: [
        { name: "planned", count: 412, items: [], note: "14 could start, none did" },
        { name: "admitted", count: 2, stop: "held: no seat, load short", items: [
          item("The board shows the compute meter", "the-board-shows-the-compute-meter", "no seat, load short"),
          item("Trail roles come from the bluebook", "trail-roles-from-bluebook", "no seat, load short"),
        ] },
        { name: "running", count: 9, stop: "2 held: waiting on a person", items: [
          item("Shape ledger accepts a live-store change", "shape-ledger-live-store-change", "waits on the owner's approval"),
          item("Two migrations rename the same column", "two-migrations-rename-one-column", "waits on the orchestrator's answer"),
          item("Board stuck list reads the impediments view", "board-stuck-reads-the-impediments-view"),
          item("Serve verb moves to core", "serve-verb-core"),
          item("Machine readings carry their time", "machine-readings-carry-their-time"),
          item("Train CI runs are recorded while the board is down", "train-ci-runs-are-recorded"),
          item("Feature page shows and switches flags", "feature-page-shows-and-switches-flags"),
          item("Review requests close when superseded", "reviewrequest-close-superseded"),
          item("Revert the landing that broke main", "red-main-1871"),
        ] },
        { name: "reviewed", count: 3, items: [
          item("Board answer reply delivers", "board-answer-reply-delivers"),
          item("Trail query", "trail-query"),
          item("Board page declaration", "board-page-declaration"),
        ] },
        { name: "landed", count: 4, stopped: true, stop: "4 held: " + HELD_RED, items: [
          item("Signalbox pressure is posted or says why", "a81f20c3d7", HELD_RED),
          item("Board lists search, sort and filter", "09be7714aa", HELD_RED),
          item("Unanswered help shows on the stuck list", "c2d94e01f5", HELD_RED),
          item("The train is a process manager", "5f6071be92", HELD_RED),
        ] },
        { name: "on the train", count: 1, stopped: true, stop: "train stopped: main is red", items: [
          item("Train 1862, three landings aboard", "train-1862", "stopped at boarding, main is red"),
        ] },
        { name: "on main", count: 31, items: [], note: "today, before 13:41" },
      ],
      day: {
        now: at("15:10"),
        red: [
          { from: at("03:12"), to: at("03:40"), ended: "fixed forward by a coder" },
          { from: at("10:05"), to: at("10:52"), ended: "reverted by the pipeline" },
          { from: at("13:41"), to: null, ended: "being reverted" },
        ],
        closed: [
          { from: at("10:05"), to: at("10:58"), why: "main red" },
          { from: at("14:02"), to: null, why: "load short" },
        ],
        landings: ["00:31", "01:02", "01:40", "02:15", "02:58", "04:10", "04:44", "05:20", "06:03", "06:39",
          "07:12", "07:50", "08:14", "08:41", "09:05", "09:33", "11:20", "11:48", "12:09", "12:31", "12:55",
          "13:12", "13:30"].map(at),
        trains: [
          { at: at("01:10"), ok: true }, { at: at("03:05"), ok: false }, { at: at("05:30"), ok: true },
          { at: at("08:20"), ok: true }, { at: at("09:58"), ok: false }, { at: at("12:15"), ok: true },
          { at: at("13:36"), ok: false },
        ],
      },
    },
    board: {
      stages: [
        stage("overdue_for_you", "Overdue for you", "3", "failed", "3 questions past their mark"),
        stage("work_items", "Work items", "412/9/1046", "working", "planned / started / done"),
        stage("sessions", "Sessions", "9", "attention", "9 busy, 3 blocked on you, of 34 in the last day"),
        stage("signal", "Signal", "Danger", "failed", "not admitting since 14:02, load short"),
        stage("fill", "Fill", "0 of 5", "attention", "started none of 14 that could start"),
        stage("local_main", "Local main", "12", "attention", "12 ahead, 0 behind origin/main; clean; quick gate red"),
        stage("integration", "Integration", "4", "failed", "4 landed and held, main is red; last advance 89 min ago"),
        stage("train", "Train", "0", "attention", "no train boards while main is red; last push 1.6 h ago"),
        stage("ci", "CI", "3", "failed", "3 failed jobs on main's head; the revert is in CI since 15:04"),
        stage("promote", "Promote", "0", "ok", "stable holds; nothing is promoted while main is red"),
        stage("release", "Release", "-", "unknown", "unknown: no v release found"),
      ],
      stuck: [
        stuck("waiting on a person", "Approve the live-store change to the shape ledger", "the owner", "11:20",
          "shape-ledger-live-store-change"),
        stuck("waiting on a person", "Say which of two migrations renames the column", "the orchestrator", "13:05",
          "two-migrations-rename-one-column"),
        stuck("waiting on a person", "Approve release 7.4.0", "the owner", "09:30", "release-7-4-0"),
        stuck("standing too long", "A reviewer's session has said nothing for 96 min", "the orchestrator", "13:34",
          "3621f6e3efc10c06eb098fb08fcc80a823f57d6b"),
        stuck("standing too long", "A landing has stood at verifying for 3.2 h", "the landing's coder", "11:58",
          "762f05a364"),
      ],
      runs: [],
    },
    fanout: {
      fill: {
        load: 21.4, limit: 16.0, cap: 5, started: 0, at: at("15:09"),
        skipped: skipped(9, "admission is closed: load 21.4 is over the limit 16.0", "waiting-item")
          .concat(skipped(3, "it waits on a work item that has not landed", "blocked-item"))
          .concat(skipped(2, "its area is held by a running item", "area-item")),
      },
    },
    metrics: [
      metric("Main red for", 1.5, "h", "failed", "since 13:41"),
      metric("CI success", 85, "%", "attention", "last 20 main runs"),
      metric("Load", 21.4, "of 16.0", "failed", "over the limit since 14:02"),
      metric("Median CI wall", 2.9, "min", "ok", "last 20 main runs"),
      metric("Work finished", 131, "items / 24 h", "ok", "today and yesterday"),
      metric("Disk free", 71.2, "GB", "ok", ""),
    ],
    roles: [],
    sessions: [],
    events: [],
  };

  return { unanswered, badDay };
})();
