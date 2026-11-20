// The instrument-panel mock-up of the Pipeline Board's main page.
//
// It reads GET /api/state (the board's own state, passed through by serve.rb), maps it to what
// each section draws, and draws every reading through one kit: a count and one line outside,
// ids, shas and full text only behind a click. It writes nothing to the board.
(function () {
  "use strict";

  const BOARD = "http://localhost:4747";
  const EVERY_MS = 10000;
  const WRONG = { attention: "warn", failed: "bad" };
  const SIGNAL = { ok: "Clear", working: "Clear", attention: "Caution", failed: "Danger", unknown: "Unread" };
  const TAG = '<span class="tag">staged</span>';
  const DAY_MS = 86400000;

  const open = new Set();
  let real = null;
  let failure = "";
  let mode = location.hash === "#bad-day" ? "bad" : "real";

  // ---- Words -------------------------------------------------------------------------------

  const el = (id) => document.getElementById(id);
  const ENT = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
  const esc = (t) => String(t ?? "").replace(/[&<>"]/g, (c) => ENT[c]);
  const list = (v) => (Array.isArray(v) ? v : []);
  const num = (v) => (v === null || v === undefined || v === "" ? NaN : Number(v));
  const plural = (n, one, many) => n + " " + (n === 1 ? one : many || one + "s");

  function hhmm(t) {
    const d = new Date(t);
    return isNaN(d) ? "" : d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  }

  // The board never says "you": a reading names a role or a person.
  const plain = (t) => String(t ?? "")
    .replace(/\b(for|on) you\b/gi, "$1 the owner")
    .replace(/\byour\b/gi, "the owner's");

  const looksLikeId = (t) => /^[0-9a-f]{7,40}$|^[0-9a-f]{8}-[0-9a-f-]{27}$/.test(String(t));

  // The same words with every id and sha taken out, for the line outside the click.
  const noIds = (t) => plain(t)
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/g, "")
    .replace(/\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b/g, "")
    .replace(/\b[\w-]*\d{6,}[\w-]*\b/g, "")
    .replace(/\s+([,;:.])/g, "$1")
    .replace(/\s{2,}/g, " ")
    .replace(/^[\s,;:]+/, "");

  function oneLine(note, max) {
    const limit = max || 92;
    const parts = noIds(note).split(/;\s*/).filter((p) => p && !/^changed:/.test(p));
    let out = "";
    for (const p of parts) {
      if (out && (out + "; " + p).length > limit) break;
      out = out ? out + "; " + p : p;
    }
    return out.length > limit ? out.slice(0, limit).replace(/\s+\S*$/, "") + "…" : out;
  }

  // ---- The kit: every box is drawn here ------------------------------------------------------

  const attrs = (key, cls) =>
    'class="' + cls.filter(Boolean).join(" ") + '" data-key="' + esc(key) + '"' + (open.has(key) ? " open" : "");

  const kv = (pairs) => "<dl>" + Object.entries(pairs)
    .filter(([, v]) => v !== null && v !== undefined && v !== "")
    .map(([k, v]) => "<dt>" + esc(k) + "</dt><dd>" + esc(v) + "</dd>").join("") + "</dl>";

  const bullets = (rows) => (rows.length ? "<ul>" + rows.map((r) => "<li>" + r + "</li>").join("") + "</ul>" : "");

  const NOTHING = "<p>Nothing more behind this reading.</p>";

  // A reading: a small label, a large count, one line. `more` opens on a click.
  function box(key, b) {
    const cls = ["box", WRONG[b.state], b.state === "unknown" && "unread", b.wide && "wide"];
    return "<details " + attrs(key, cls) + "><summary>" +
      '<span class="label">' + esc(b.label) + (b.staged ? TAG : "") + "</span>" +
      '<span class="count">' + esc(b.count) + (b.unit ? "<small>" + esc(b.unit) + "</small>" : "") + "</span>" +
      '<span class="line">' + esc(b.line) + "</span></summary>" +
      '<div class="more">' + (b.more || NOTHING) + "</div></details>";
  }

  // One plain line, with an optional count before it and a time after it.
  function row(key, r) {
    return "<details " + attrs(key, ["row", WRONG[r.state]]) + "><summary>" +
      (r.count === undefined ? "" : '<span class="num">' + esc(r.count) + "</span>") +
      '<span class="line">' + esc(r.line) + (r.staged ? TAG : "") + "</span>" +
      (r.when ? '<span class="when">' + esc(r.when) + "</span>" : "") + "</summary>" +
      '<div class="more">' + (r.more || NOTHING) + "</div></details>";
  }

  function heading(id, name, count, line, staged) {
    el(id).innerHTML = '<span class="name">' + esc(name) + (staged ? TAG : "") + "</span>" +
      '<span class="num">' + esc(count) + "</span>" + '<span class="line">' + esc(line) + "</span>";
  }

  // ---- 1. The strip --------------------------------------------------------------------------

  const metric = (st, id) => list(st.metrics).find((m) => m.id === id);

  const STAGES = {
    overdue_for_you: (s) => ({
      label: "Overdue for the owner",
      line: plural(num(s.value) || 0, "item") + " past the mark, waiting on the owner",
    }),
    work_items: (s) => {
      const [planned, started, done] = String(s.value).split("/");
      return { label: "Work in flight", count: started, line: planned + " planned, " + done + " done" };
    },
    signal: (s) => ({
      wide: true,
      count: /^[A-Za-z]/.test(s.value) ? s.value : SIGNAL[s.state] || "Unread",
      line: oneLine(String(s.note).replace(/^unknown:\s*/, ""), 120),
    }),
    fill: (s, st) => {
      const fill = (st.fanout || {}).fill;
      return fill && !st.staged ? { line: fill.started + " started under a cap of " + fill.cap } : {};
    },
    local_main: (s) => ({ line: oneLine(String(s.note).replace(/^local main\s+\S+,\s*/, "")) }),
    train: (s, st) => {
      const ahead = metric(st, "ahead");
      return looksLikeId(s.value) && ahead ? { count: ahead.value, unit: "not pushed" } : {};
    },
  };

  function stageBox(s, st) {
    const custom = (STAGES[s.key] || (() => ({})))(s, st);
    const hidden = looksLikeId(s.value);
    const more = kv({
      "Full reading": plain(s.note), "Value": hidden ? s.value : "", "Read from": s.source,
      "Read at": hhmm(s.fresh_at), "Since": s.since ? hhmm(s.since) : "",
    });
    return box("stage:" + s.key, Object.assign({
      label: plain(s.label), count: hidden ? "–" : s.value, unit: s.unit, line: oneLine(s.note), state: s.state, more,
    }, custom));
  }

  function fillRow(st) {
    const fill = (st.fanout || {}).fill;
    if (!fill) return "";
    const skipped = list(fill.skipped);
    const why = {};
    skipped.forEach((s) => { (why[plain(s.reason)] = why[plain(s.reason)] || []).push(s.slug); });
    const reasons = Object.entries(why).sort((a, b) => b[1].length - a[1].length);
    const said = reasons.length === 1 ? lower(reasons[0][0]) : reasons.slice(0, 3).map(([reason, slugs]) => slugs.length + " because " + lower(reason)).join("; ");
    const old = fill.at && Date.now() - new Date(fill.at) > 3600000 && !st.staged
      ? " (this fill was read " + new Date(fill.at).toLocaleDateString("en-GB", { day: "numeric", month: "short" }) + ")"
      : "";
    const line = skipped.length
      ? "waiting " + (skipped.length === 1 ? "item" : "items") + " did not start: " + said + old
      : "Every item that could start did" + old;
    const more = reasons.map(([reason, slugs]) => "<p>" + esc(slugs.length + " · " + reason) + "</p>" +
      bullets(slugs.slice(0, 25).map((s) => "<code>" + esc(s) + "</code>")
        .concat(slugs.length > 25 ? ["and " + (slugs.length - 25) + " more"] : []))).join("") +
      kv({ "Load": fill.load, "Limit": fill.limit, "Cap": fill.cap, "Started": fill.started, "Fill read at": fill.at });
    return row("fill", { count: skipped.length, line, more, state: st.staged && skipped.length ? "attention" : "" });
  }

  const lower = (t) => t.charAt(0).toLowerCase() + t.slice(1);

  function drawStrip(st) {
    const stages = list((st.board || {}).stages);
    const wrong = stages.filter((s) => WRONG[s.state]).length;
    heading("h-strip", "The pipeline", stages.length ? wrong : "–",
      stages.length ? (wrong ? "of " + stages.length + " readings are off their mark" : "every reading is on its mark") : "");
    el("strip").innerHTML = stages.map((s) => stageBox(s, st)).join("");
    el("fill").innerHTML = fillRow(st);
  }

  // ---- 2. The stuck list ---------------------------------------------------------------------

  const OVERDUE = /(\S+) at (\w+) for ([\d.]+) h:/g;

  function overdueEntries(st) {
    const stage = list((st.board || {}).stages).find((s) => s.key === "overdue_for_you");
    if (!stage || st.staged) return [];
    return Array.from(String(stage.note).matchAll(OVERDUE)).map((m) => ({
      group: "waiting on a person",
      line: "Stood at " + m[2] + " for " + m[3] + " h; waits on the owner",
      more: kv({ "Item": m[1], "Stage": m[2], "Hours": m[3] }),
    }));
  }

  function parkedEntries(st) {
    const parked = num((st.integration || {}).needs_human);
    if (!(parked > 0) || st.staged) return [];
    const runs = list(st.integration.runs).filter((r) => r.parked).map((r) => "<code>" + esc(r.short) + "</code>");
    return [{
      group: "waiting on a person",
      line: plural(parked, "landed run") + " parked before the train; " + (parked === 1 ? "waits" : "wait") + " on the owner",
      more: bullets(runs) || NOTHING,
    }];
  }

  function stuckEntries(st) {
    const runs = list((st.board || {}).runs);
    const rows = list((st.board || {}).stuck).map((r) => {
      const run = runs.find((x) => x.run === r.owner_run);
      const role = run ? run.role : /orchestrator/.test(r.owner_run || "") ? "orchestrator" : "";
      const who = r.waits_on ? "waits on " + plain(r.waits_on) : "no one is named to move it";
      const whose = st.staged || !role ? "" : (/^[aeiou]/.test(role) ? "An " : "A ") + role + "'s run: ";
      return {
        group: r.group,
        line: whose + (whose ? lower(noIds(r.what)) : noIds(r.what)) + "; " + who,
        when: r.since ? "since " + hhmm(r.since) : "",
        more: kv({ "Kind": r.kind, "Full reading": plain(r.what), "Run": r.owner_run, "Since": r.since }) +
          (r.link ? '<p><a href="' + esc(BOARD + r.link) + '">Open this run on the board</a></p>' : ""),
      };
    });
    return overdueEntries(st).concat(parkedEntries(st), rows);
  }

  function group(name, cls, entries) {
    const mine = entries.filter((e) => e.group === name);
    return '<div class="group ' + cls + (mine.length ? " has" : "") + '"><h3><span class="num">' + mine.length +
      '</span><span class="label">' + esc(name) + "</span></h3>" +
      (mine.length ? mine.map((e, i) => row("stuck:" + name + ":" + i, e)).join("") : '<p class="none">Nothing.</p>') +
      "</div>";
  }

  function drawStuck(st) {
    const entries = stuckEntries(st);
    heading("h-stuck", "Stuck", entries.length,
      entries.length ? "each line names who it waits on" : "nothing is stuck; the pipeline is flowing");
    el("stuck").innerHTML = group("waiting on a person", "person", entries) + group("standing too long", "", entries);
  }

  // ---- 3. The line ---------------------------------------------------------------------------

  function realLine(st) {
    const work = list(st.open_work);
    const runs = list((st.integration || {}).runs);
    const stuck = list((st.board || {}).stuck);
    const staged = (st.unanswered || {}).line || {};
    const planned = work.filter((w) => w.status === "planned");
    const running = work.filter((w) => w.status === "started").map((w) => {
      const held = stuck.find((s) => s.owner_run === w.slug);
      return { title: w.title, id: w.slug, held: held ? plain(held.what) : plain(w.reason || "") };
    });
    const landing = (r) => ({
      title: "A landing, " + String(r.stage).replace(/_/g, " "), id: r.short,
      held: r.parked ? "parked, waits on the owner" : "",
    });
    const landed = runs.filter((r) => /^(landed|verified|needs_human)$/.test(r.stage)).map(landing);
    const train = runs.filter((r) => /^(boarding|boarded|pushed|ci_running)$/.test(r.stage)).map(landing);
    const today = new Date().toDateString();
    const onMain = list(st.ci_runs).filter((r) => r.conclusion === "success" && new Date(r.started).toDateString() === today);
    return [
      { name: "planned", count: planned.length, items: [],
        list: planned.slice(0, 15).map((w) => ({ title: w.title, id: w.slug })), note: "next by priority behind the click" },
      { name: "admitted", staged: true, items: list(staged.admitted), count: list(staged.admitted).length },
      station("running", running),
      { name: "reviewed", staged: true, items: list(staged.reviewed), count: list(staged.reviewed).length },
      station("landed", landed),
      station("on the train", train),
      { name: "on main", count: onMain.length, items: [], note: "green pushes today" },
    ];
  }

  function station(name, items) {
    const held = items.filter((i) => i.held);
    const stop = held.length ? held.length + " held: " + oneLine(held[0].held, 56) : "";
    return { name, count: items.length, items, stop };
  }

  function stationHtml(s) {
    const items = list(s.items);
    const cls = ["station", s.stop && "held", s.stopped && "stopped"];
    const marks = items.slice(0, 24).map((i) => "<i" + (i.held ? ' class="held"' : "") + "></i>").join("");
    const rows = items.concat(list(s.list)).map((i) =>
      esc(i.title) + " <code>" + esc(i.id) + "</code>" + (i.held ? " · held: " + esc(i.held) : ""));
    return "<details " + attrs("line:" + s.name, cls) + "><summary>" +
      '<span class="label">' + esc(s.name) + (s.staged ? TAG : "") + "</span>" +
      '<span class="count">' + esc(s.count) + "</span>" + '<span class="marks">' + marks + "</span>" +
      '<span class="line">' + esc(s.stop || s.note || "") + "</span></summary>" +
      '<div class="more">' + (bullets(rows) || NOTHING) + "</div></details>";
  }

  function drawLine(st) {
    const stations = st.staged ? st.staged.line : realLine(st);
    const flight = stations.slice(1, -1).reduce((n, s) => n + (Number(s.count) || 0), 0);
    const held = stations.reduce((n, s) => n + list(s.items).filter((i) => i.held).length, 0);
    heading("h-line", "The line", flight, "in flight between planned and main" + (held ? "; " + held + " held at a stop" : ""));
    el("line").innerHTML = stations.map(stationHtml).join("");
  }

  // ---- 4. The day ----------------------------------------------------------------------------

  function redEpisodes(runs, midnight) {
    const sorted = list(runs).filter((r) => r.started).sort((a, b) => new Date(a.started) - new Date(b.started));
    const out = [];
    let open = null;
    sorted.forEach((r) => {
      if (r.conclusion === "failure" && !open) open = { from: r.started, to: null, ended: "still red" };
      if (r.conclusion === "success" && open) { out.push(Object.assign(open, { to: r.started, ended: "CI went green" })); open = null; }
    });
    if (open) out.push(open);
    return out.filter((e) => !e.to || new Date(e.to) >= midnight);
  }

  function realDay(st, midnight) {
    const today = (t) => t && new Date(t) >= midnight;
    const now = Date.now();
    const landed = list((st.integration || {}).runs).map((r) => r.at).filter(today);
    const staged = list((st.unanswered || {}).landings).filter((t) => new Date(t) < now);
    return {
      now,
      landings: landed.length ? landed : staged,
      landingsStaged: !landed.length,
      red: redEpisodes(st.ci_runs, midnight),
      closed: list((st.unanswered || {}).closed).filter((c) => new Date(c.to) < now).map((c) => Object.assign({ staged: true }, c)),
      closedStaged: true,
      trains: list(st.train_ci_runs).filter((r) => today(r.started)).map((r) => ({ at: r.started, ok: r.conclusion !== "failure" })),
    };
  }

  function lane(name, count, marks, staged) {
    return '<div class="lane"><span class="lane-name">' + esc(name) + (staged ? TAG : "") + "</span>" +
      '<div class="lane-track">' + marks + '</div><span class="n">' + esc(count) + "</span></div>";
  }

  function drawDay(st) {
    const midnight = new Date(st.staged ? st.staged.day.now : Date.now());
    midnight.setHours(0, 0, 0, 0);
    const day = st.staged ? st.staged.day : realDay(st, midnight);
    const now = new Date(day.now);
    const pct = (t) => Math.max(0, Math.min(100, ((new Date(t) - midnight) / DAY_MS) * 100));
    const span = (s, cls) => '<i class="span ' + cls + (s.staged ? " staged" : "") + '" style="left:' + pct(s.from) +
      "%;width:" + (pct(s.to || now) - pct(s.from)) + '%"></i>';
    const over = '<i class="now" style="left:' + pct(now) + '%"></i><i class="later" style="width:' + (100 - pct(now)) + '%"></i>';
    const minutes = (s) => Math.round((new Date(s.to || now) - new Date(s.from)) / 60000);
    const closedMin = day.closed.reduce((n, s) => n + minutes(s), 0);

    el("day").innerHTML =
      lane("main red", day.red.length, day.red.map((s) => span(s, "bad")).join("") + over) +
      lane("admission closed", closedMin + "m", day.closed.map((s) => span(s, "warn")).join("") + over, day.closedStaged) +
      lane("landings", day.landings.length, day.landings.map((t) => '<i class="tick" style="left:' + pct(t) + '%"></i>').join("") + over, day.landingsStaged) +
      lane("trains", day.trains.length, day.trains.map((t) =>
        '<i class="tick train' + (t.ok ? "" : " bad") + '" style="left:' + pct(t.at) + '%"></i>').join("") + over) +
      '<div class="axis"><span></span><div class="hours">' + [0, 6, 12, 18, 24].map((h) =>
        '<span style="left:' + (h / 24) * 100 + '%">' + String(h).padStart(2, "0") + ":00</span>").join("") + "</div><span></span></div>";

    heading("h-day", "Today", day.red.length, plural(day.red.length, "red episode") + ", admission closed " +
      closedMin + " min, " + plural(day.landings.length, "landing") + ", " + plural(day.trains.length, "train") +
      (day.closedStaged ? "; closed admission" + (day.landingsStaged ? " and landings are" : " is") + " staged" : ""));
    el("day-list").innerHTML = dayRows(day, minutes);
  }

  function dayRows(day, minutes) {
    const until = (s) => hhmm(s.from) + " to " + (s.to ? hhmm(s.to) : "now");
    const red = day.red.map((s, i) => row("day:red:" + i, {
      state: "failed", when: until(s), line: "Main red for " + minutes(s) + " min: " + s.ended,
      more: kv({ "From": s.from, "To": s.to || "still open" }),
    }));
    const closed = day.closed.map((s, i) => row("day:closed:" + i, {
      state: s.staged ? "" : "attention", staged: s.staged, when: until(s),
      line: "Admission closed for " + minutes(s) + " min: " + s.why, more: kv({ "From": s.from, "To": s.to || "still closed" }),
    }));
    const failed = day.trains.filter((t) => !t.ok);
    const trains = failed.length ? [row("day:trains", {
      state: "attention", line: plural(failed.length, "train") + " failed CI: at " + failed.map((t) => hhmm(t.at)).join(", "),
      more: kv({ "Trains today": day.trains.length }),
    })] : [];
    return red.concat(closed, trains).join("");
  }

  // ---- 5. Everything else --------------------------------------------------------------------

  function drawRest(st) {
    const metrics = list(st.metrics);
    const roles = list(st.roles);
    const events = list(st.events);
    const off = metrics.filter((m) => WRONG[m.state]).length;
    const key = "rest";
    const body = "<h3>Measures</h3>" + '<div class="metrics">' + metrics.map((m) => box("metric:" + m.id, {
      label: m.label, count: m.value === null || m.value === undefined ? "–" : m.value, unit: m.unit,
      line: oneLine(m.detail || "", 60), state: m.state, more: kv({ "Detail": plain(m.detail), "Since": m.since }),
    })).join("") + "</div>" +
      (roles.length ? "<h3>Roles</h3>" + roles.map((r, i) => row("role:" + i, {
        count: r.live, line: r.name + ": " + plural(list(r.working).length, "session") + " working, " + (r.waiting || 0) + " waiting",
        more: bullets(list(r.working).map((w) => esc(noIds(w.detail || w.name)) + " <code>" + esc(w.id) + "</code>")),
      })).join("") : "") +
      (events.length ? "<h3>Newest events</h3>" + events.slice(0, 20).map((e, i) => row("event:" + i, {
        line: e.name, when: hhmm(e.at), more: kv({ "Aggregate": e.aggregate, "Id": e.id, "Source": e.source }),
      })).join("") : "");
    el("rest").innerHTML = "<details " + attrs(key, ["rest", off && "warn"]) + "><summary>" +
      '<span class="label">Everything else</span><span class="num">' + off + "</span>" +
      '<span class="line">of ' + plural(metrics.length, "measure") + " off the mark; " + plural(roles.length, "role") +
      ", " + plural(list(st.sessions).length, "session") + ", " + plural(events.length, "event") + "</span></summary>" + body + "</details>";
  }

  // ---- The red main, the failure line and the page -------------------------------------------

  function redMain(st) {
    const staged = st.staged && st.staged.red_main;
    const red = metric(st, "red");
    const ci = list((st.board || {}).stages).find((s) => s.key === "ci");
    if (!staged && !(red && num(red.value) > 0) && !(ci && ci.state === "failed")) return "";
    const since = staged ? "since " + hhmm(staged.since) : red && num(red.value) > 0 ? "for " + red.value + " h" : "";
    const line = staged ? staged.line : oneLine(ci ? ci.note : "CI on main is failing", 200);
    const more = staged ? kv(staged.more) : kv({ "CI reading": ci ? plain(ci.note) : "" });
    return "<details " + attrs("red-main", ["red-main"]) + "><summary>" +
      '<span class="count">Main is red ' + esc(since) + "</span>" + '<span class="line">' + esc(line) + "</span></summary>" +
      '<div class="more">' + more + "</div></details>";
  }

  // A failed reading is said once, here, in plain words.
  function failureLine(st) {
    const said = [];
    if (failure) said.push(failure);
    if (st.refresh_error) said.push("The board could not refresh: " + noIds(st.refresh_error));
    if (st.live_store_problem) said.push("The board cannot read its live store: " + noIds(st.live_store_problem));
    if (String(st.stale) === "true") said.push("The board's own reading is " + st.stale_seconds + " s old");
    const missing = [["the strip", (st.board || {}).stages], ["the stuck list", (st.board || {}).stuck],
      ["the fill", (st.fanout || {}).fill], ["the Work items", st.open_work]]
      .filter(([, v]) => v === undefined || v === null).map(([name]) => name);
    if (missing.length) said.push("The board's state holds no reading for " + missing.join(", "));
    return said.join(". ");
  }

  function draw() {
    const bad = mode === "bad";
    const st = bad ? window.STAGED.badDay : real ? Object.assign({}, real, { unanswered: window.STAGED.unanswered }) : null;
    el("mode-real").setAttribute("aria-pressed", String(!bad));
    el("mode-bad").setAttribute("aria-pressed", String(bad));
    el("staged-notice").hidden = !bad;
    const said = bad ? "" : st ? failureLine(st) : failure || "";
    el("failure").hidden = !said;
    el("failure").textContent = said;
    if (!st) { el("read").textContent = "no reading yet"; return; }
    el("read").textContent = (bad ? "staged at " : "read at ") + hhmm(st.generated_at);
    el("red-main").innerHTML = redMain(st);
    drawStrip(st);
    drawStuck(st);
    drawLine(st);
    drawDay(st);
    drawRest(st);
  }

  async function read() {
    try {
      const answer = await fetch("/api/state", { cache: "no-store" });
      const body = await answer.json();
      if (!answer.ok) throw new Error(body.error || "the board answered " + answer.status);
      real = body;
      failure = "";
    } catch (error) {
      failure = "The board on :4747 could not be read at " + hhmm(Date.now()) +
        (real ? "; this page shows the reading from " + hhmm(real.generated_at) : "; there is no reading to show");
    }
    if (mode === "real") draw();
  }

  function setMode(next) {
    mode = next;
    history.replaceState(null, "", next === "bad" ? "#bad-day" : location.pathname);
    draw();
  }

  document.addEventListener("toggle", (event) => {
    const key = event.target.dataset && event.target.dataset.key;
    if (!key) return;
    if (event.target.open) open.add(key); else open.delete(key);
  }, true);
  el("mode-real").addEventListener("click", () => setMode("real"));
  el("mode-bad").addEventListener("click", () => setMode("bad"));

  draw();
  read();
  setInterval(read, EVERY_MS);
})();
