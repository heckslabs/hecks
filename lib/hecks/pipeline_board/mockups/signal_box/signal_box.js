"use strict";

// Draws the Pipeline Board's main page as a railway signal box from one state object: the
// board's own GET /api/state, or the staged bad day. It only reads.

const BOARD = "http://localhost:4747";
const ASPECT = { ok: "clear", working: "clear", attention: "caution", failed: "danger" };
const STATIONS = ["planned", "admitted", "running", "reviewed", "landed", "on the train", "on main"];
const AT_LANDED = ["landed", "verifying", "verified", "needs_human", "verify_failed"];
const ON_TRAIN = ["boarding", "boarded", "pushed", "ci_running"];

let now = Date.now();
let missing = [];
let seen = "";

// ---- small helpers -------------------------------------------------------------------------

const esc = (text) => String(text ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
// The board never says "you": the present board's wording is turned to name the owner.
const plain = (text) => String(text ?? "").replace(/\byou\b/gi, "the owner");
const say = (text) => esc(plain(text));
const cut = (text, length) => (text.length > length ? `${text.slice(0, length - 1).trimEnd()}…` : text);
const lamp = (aspect) => `<i class="lamp ${aspect || "dark"}"></i>`;
const tag = (staged) => (staged ? '<span class="staged">staged</span>' : "");
const clock = (time) => new Date(time).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

function when(time) {
  const date = new Date(time);
  if (!time || Number.isNaN(date.getTime())) return "";
  if (date.toDateString() === new Date(now).toDateString()) return clock(date);
  return `${date.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" })} ${clock(date)}`;
}

function ago(time) {
  const minutes = Math.round((now - Date.parse(time)) / 60000);
  if (minutes < 90) return `${minutes} min ago`;
  if (minutes < 48 * 60) return `${Math.round(minutes / 60)} h ago`;
  return `${Math.round(minutes / 1440)} days ago`;
}

// A list the board sent, or none; a reading the board could not make is remembered, to be said once.
function list(value, name) {
  if (Array.isArray(value)) return value;
  if (value && value.unknown) missing.push([name, value.unknown]);
  return [];
}

function record(value, name) {
  if (value && value.unknown) missing.push([name, value.unknown]);
  return value && !value.unknown && typeof value === "object" ? value : {};
}

function groupBy(items, key) {
  const groups = new Map();
  items.forEach((item) => groups.set(key(item), [...(groups.get(key(item)) || []), item]));
  return [...groups.entries()].sort((a, b) => b[1].length - a[1].length);
}

// ---- 1. block instruments ------------------------------------------------------------------

function signalReading(state, stages) {
  const staged = state.extras.signal;
  if (staged) return { ...staged, text: staged.reading, staged: true };
  const stage = stages.find((s) => s.name === "Signal");
  if (!stage) return { aspect: "dark", text: "No reading: the board sent no signal" };
  if (!ASPECT[stage.state]) return { aspect: "dark", text: `No reading: ${plain(stage.detail).replace(/^unknown:\s*/, "")}` };
  return { aspect: ASPECT[stage.state], text: plain(stage.detail), since: stage.since };
}

function signalHead(aspect) {
  const lit = (name) => (aspect === name ? name : "dark");
  return `<div class="post"><div class="head">${lamp(lit("clear"))}${lamp(lit("caution"))}${lamp(lit("danger"))}</div></div>`;
}

function instrument(stage) {
  const aspect = ASPECT[stage.state] || "dark";
  const detail = plain(stage.detail);
  const one = aspect === "dark" ? `No reading: ${detail.replace(/^unknown:\s*/, "")}` : detail.split("; ")[0];
  const count = String(stage.count ?? "");
  return `<details class="inst ${aspect}">
    <summary>${lamp(aspect)}<span class="name">${say(stage.name)}</span>
      <b class="count${count.length > 7 ? " long" : ""}">${esc(count === "-" ? "" : count)}</b>
      <span class="one">${esc(cut(one, 64))}</span></summary>
    <p class="full">${esc(detail)}</p><p class="since">reading since ${esc(when(stage.since))}</p>
  </details>`;
}

function reasonPlain(reason) {
  const cap = /cap (\d+) reached \((\d+) started/.exec(reason);
  return cap ? `the cap of ${cap[1]} sessions is full, ${cap[2]} are running` : plain(reason).replace(/^held:\s*/, "");
}

function heldGroup([reason, items]) {
  const more = items.length > 40 ? `<br>and ${items.length - 40} more` : "";
  return `<details class="held"><summary><b>${items.length}</b> held: ${esc(reasonPlain(reason))}</summary>
    <p class="ids">${items.slice(0, 40).map((item) => esc(item.slug)).join("<br>")}${more}</p></details>`;
}

// The four largest reasons are drawn; the rest sit behind one line, so a long tail stays one box.
function heldGroups(skipped) {
  const groups = groupBy(skipped, (item) => item.reason);
  const rest = groups.slice(4);
  if (!rest.length) return groups.map(heldGroup).join("");
  const items = rest.reduce((sum, group) => sum + group[1].length, 0);
  return `${groups.slice(0, 4).map(heldGroup).join("")}<details class="more">
    <summary><b>${items}</b> held for ${rest.length} other reasons</summary>${rest.map(heldGroup).join("")}</details>`;
}

function fillPanel(state) {
  const fill = record(record(state.fanout, "the fill and the fan-out").fill, "the fill");
  if (!fill.at) return '<div class="platform"><h3>Held at the platform</h3><p class="none">No fill has been read.</p></div>';
  const skipped = fill.skipped || [];
  const old = now - Date.parse(fill.at) > 3600e3;
  const read = `${old ? lamp("caution") : ""}this fill was read ${esc(old ? ago(fill.at) : `at ${when(fill.at)}`)}`;
  return `<div class="platform">
    <h3>Held at the platform <span class="sub">why each waiting item did not start</span></h3>
    <p class="summary"><b>${(fill.would_start || []).length}</b> would start, <b>${skipped.length}</b> held.
      Load ${esc(fill.load)} against a limit of ${esc(fill.limit)}; ${esc(fill.started)} running under a cap of ${esc(fill.cap)};
      <span class="${old ? "old" : ""}">${read}</span>.</p>
    ${heldGroups(skipped) ||'<p class="none">Nothing is held.</p>'}
  </div>`;
}

function partBlock(state) {
  const stages = list(state.stages, "the stages");
  const signal = signalReading(state, stages);
  const more = signal.more ? `<details><summary>the reading</summary><p>${esc(signal.more)}</p></details>` : "";
  const strip = stages.filter((stage) => stage.name !== "Signal").map(instrument).join("");
  return `<div class="block">
    <div class="signal ${signal.aspect}">${signalHead(signal.aspect)}
      <div class="reading"><span class="label">Signalbox ${tag(signal.staged)}</span>
        <p class="aspect">${esc(signal.text)}</p>${more}</div></div>
    <div class="instruments">${strip || '<p class="none">No stage reading has arrived.</p>'}</div>
  </div>${fillPanel(state)}`;
}

// ---- 2. sidings ----------------------------------------------------------------------------

function stuckEntries(state) {
  const sessions = list(state.sessions, "the sessions");
  const entries = list(record(state.board).stuck).map((entry) => {
    const session = sessions.find((s) => s.run && s.run === entry.owner_run);
    return { ...entry, subject: entry.subject || (session && session.name) || cut(String(entry.owner_run || entry.kind), 14) };
  });
  const parked = record(state.integration).needs_human;
  const listed = entries.some((entry) => entry.group === "waiting on a person");
  if (parked && !listed) {
    entries.push({ group: "waiting on a person", subject: `${parked} landed runs`, what: "parked until a person looks", waits_on: "the owner", kind: "integration, needs_human" });
  }
  return entries;
}

function wagon(entry) {
  const waits = entry.waits_on ? ` · waits on <b>${say(entry.waits_on)}</b>` : "";
  const link = entry.link ? `<a href="${BOARD}${esc(entry.link)}">open the run on the board</a>` : "";
  return `<details class="wagon"><summary><span class="what">${say(entry.subject)}: ${say(entry.what)}</span>${waits}</summary>
    <p class="ids">${esc(entry.kind || "")}${entry.since ? ` · since ${esc(when(entry.since))}` : ""}
      ${entry.owner_run ? `<br>run ${esc(entry.owner_run)}` : ""} ${link}</p></details>`;
}

function siding(name, entries, aspect) {
  const wagons = entries.map(wagon).join("") || '<p class="none">The siding is empty.</p>';
  return `<div class="siding"><h3>${lamp(entries.length ? aspect : "clear")}${name} <b>${entries.length}</b></h3>
    <div class="rail">${wagons}</div></div>`;
}

function partSidings(state) {
  const entries = stuckEntries(state);
  const waiting = entries.filter((entry) => entry.group === "waiting on a person");
  const standing = entries.filter((entry) => entry.group !== "waiting on a person");
  return `<div class="sidings">${siding("Waiting on a person", waiting, "danger")}${siding("Standing too long", standing, "caution")}</div>`;
}

// ---- 3. the line ---------------------------------------------------------------------------

function trainsOf(state) {
  const work = list(state.open_work, "the open work items");
  const rows = new Map(list(record(state.fanout).rows).map((row) => [row.slug, row]));
  const sessions = list(state.sessions);
  const started = work.filter((item) => item.status === "started").map((item) => {
    const flag = ((rows.get(item.slug) || {}).flags || [])[0];
    const seat = sessions.find((s) => [s.run, s.work_item].includes(item.slug) && ["working", "blocked"].includes(s.state));
    const blocked = seat && seat.state === "blocked" ? "blocked on a question" : "";
    const hold = item.held || blocked || (flag && (flag.detail || flag)) || "";
    return { at: seat ? "running" : "admitted", name: item.slug, more: `${item.title}${seat ? ` · session ${seat.name}` : ""}`, hold };
  });
  const runs = list(record(state.integration, "the landings").runs).map((run) => {
    const at = ON_TRAIN.includes(run.stage) ? "on the train" : AT_LANDED.includes(run.stage) ? "landed" : "on main";
    const hold = run.held || (run.parked ? "parked: waits on a person" : "");
    return { at, name: run.name || run.short, more: `${run.short} · ${run.stage}${run.at ? ` · ${when(run.at)}` : ""}`, hold };
  });
  const reviewed = (state.extras.reviewed || []).map((item) => ({ at: "reviewed", name: item.slug, more: item.title, hold: "", staged: true }));
  return { trains: [...started, ...reviewed, ...runs], planned: work.filter((item) => item.status === "planned").length };
}

function train(item) {
  const stop = item.hold ? `<span class="stop">${lamp("danger")}held: ${say(cut(String(item.hold), 90))}</span>` : "";
  return `<details class="train${item.hold ? " held" : ""}${item.staged ? " is-staged" : ""}">
    <summary><span class="nm">${esc(cut(item.name, 30))}</span>${tag(item.staged)}${stop}</summary>
    <p class="ids">${esc(item.name)}<br>${say(item.more)}${item.hold ? `<br>held: ${say(item.hold)}` : ""}</p></details>`;
}

function stationNote(name, here, planned, state) {
  const staged = (state.extras.notes || {})[name];
  if (staged) return staged;
  if (name === "planned") return `${planned} in the yard`;
  if (name === "landed") {
    const ahead = list(state.metrics).find((metric) => metric.label === "Commits not pushed");
    return ahead ? `${ahead.value} commits not yet on origin/main` : `${here.length} here`;
  }
  if (name === "reviewed" && !state.extras.all) return "no query answers this yet";
  return here.length ? `${here.length} here` : "empty";
}

function station(name, trains, planned, state) {
  const here = trains.filter((item) => item.at === name);
  const aspect = here.some((item) => item.hold) ? "danger" : here.length || (name === "planned" && planned) ? "clear" : "dark";
  const shown = here.slice(0, 6).map(train).join("");
  const rest = here.length > 6 ? `<details class="more"><summary>and ${here.length - 6} more</summary>${here.slice(6).map(train).join("")}</details>` : "";
  return `<div class="station"><h3>${lamp(aspect)}${name}</h3><p class="note">${esc(stationNote(name, here, planned, state))}</p>${shown}${rest}</div>`;
}

function trackDiagram() {
  const stop = (x, y) => `<circle cx="${x}" cy="${y}" r="7"/>`;
  return `<svg class="track" viewBox="0 0 1400 76" aria-hidden="true">
    <path class="main dim" d="M0 22 H870"/><path class="main" d="M870 22 H1372"/><path class="arrow" d="M1372 14 l16 8 l-16 8 z"/>
    <path class="branch" d="M34 54 H800 L872 22"/><path class="buffer" d="M34 44 V64"/>
    <text x="4" y="14">main</text><text x="4" y="74">branch</text><text x="1396" y="46" text-anchor="end">origin/main</text>
    ${[100, 300, 500, 700].map((x) => stop(x, 54)).join("")}${[900, 1100, 1300].map((x) => stop(x, 22)).join("")}
  </svg>`;
}

function partLine(state) {
  const { trains, planned } = trainsOf(state);
  return `<div class="line">${trackDiagram()}
    <div class="stations">${STATIONS.map((name) => station(name, trains, planned, state)).join("")}</div></div>`;
}

// ---- 4. the day ----------------------------------------------------------------------------

// Red episodes read from the runs of main the board lists: first red to the next green.
function episodesOf(runs) {
  const episodes = [];
  let open = null;
  runs.filter((run) => run.event === "push").sort((a, b) => a.started.localeCompare(b.started)).forEach((run) => {
    if (run.conclusion === "failure" && !open) open = { from: run.started, to: null, ended: "still red" };
    if (run.conclusion === "success" && open) {
      episodes.push({ ...open, to: run.started, ended: `green again with ${run.sha}` });
      open = null;
    }
  });
  return open ? [...episodes, open] : episodes;
}

function dayOf(state) {
  const extras = state.extras;
  const runs = list(state.ci_runs, "the runs of main");
  const landed = list(record(state.integration).runs).filter((run) => run.at).map((run) => run.at);
  const boarded = list(record(state.daily_health).boarded_by_hand).map((b) => ({ at: b.at, ok: null, label: `boarded ${b.key.slice(0, 7)}` }));
  const pushed = runs.filter((run) => run.event === "push").map((run) => ({ at: run.started, ok: run.conclusion === "success", label: run.sha }));
  return {
    episodes: extras.episodes || episodesOf(runs),
    admission: extras.admission || [],
    admissionStaged: !extras.all,
    landings: extras.landings || landed,
    trains: extras.trains || [...boarded, ...pushed],
    load: record(state.load_history),
  };
}

function dayScale() {
  const start = new Date(now).setHours(0, 0, 0, 0);
  const x = (time) => 110 + ((Math.min(Date.parse(time) || time, now) - start) / 864e5) * 1270;
  const today = (time) => (Date.parse(time) || time) >= start;
  return { x, today, start };
}

function spanBars(spans, scale, y, kind) {
  return spans.filter((span) => scale.today(span.to || now)).map((span) => {
    const from = Math.max(scale.x(span.from), 110);
    const width = Math.max(scale.x(span.to || now) - from, 4);
    return `<rect class="${kind}${span.to ? "" : " open"}" x="${from}" y="${y}" width="${width}" height="14" rx="2"><title>${esc(span.ended || span.why)}</title></rect>`;
  }).join("");
}

// The time of a mark: a bare time, or an entry holding one.
const timeOf = (mark) => (typeof mark === "string" ? mark : mark.at);

function ticks(marks, scale, y, kind) {
  return marks.filter((mark) => scale.today(timeOf(mark))).map((mark) => {
    const x = scale.x(timeOf(mark));
    const state = mark.ok === false ? " bad" : mark.ok === null ? " out" : "";
    return `<path class="${kind}${state}" d="M${x} ${y} v14"><title>${esc(mark.label || "landed")} ${esc(clock(timeOf(mark)))}</title></path>`;
  }).join("");
}

function loadCurve(load, scale) {
  const samples = (load.samples || []).filter((sample) => scale.today(sample[0]));
  if (!samples.length) return "";
  const top = Math.max(load.limit * 1.4, ...samples.map((sample) => sample[1]));
  const y = (value) => 172 - (value / top) * 44;
  const points = samples.map((sample) => `${scale.x(sample[0]).toFixed(1)},${y(sample[1]).toFixed(1)}`).join(" ");
  return `<path class="limit" d="M110 ${y(load.limit)} H1380"/><text class="small" x="1380" y="${y(load.limit) - 3}" text-anchor="end">limit ${load.limit}</text>
    <polyline class="load" points="${points}"/>`;
}

function dayStrip(day) {
  const scale = dayScale();
  const hours = Array.from({ length: 13 }, (_, i) => i * 2).map((hour) => {
    const x = 110 + (hour / 24) * 1270;
    return `<path class="hour" d="M${x} 20 V176"/><text class="small" x="${x}" y="14" text-anchor="middle">${String(hour).padStart(2, "0")}:00</text>`;
  }).join("");
  const rows = ["main red", "admission closed", "landings", "trains", "load"];
  const labels = rows.map((row, i) => `<text x="0" y="${41 + i * 26 + (i === 4 ? 16 : 0)}">${row}</text>`).join("");
  return `<svg class="strip" viewBox="0 0 1400 182" role="img" aria-label="Today, hour by hour">${hours}${labels}
    ${spanBars(day.episodes, scale, 30, "red")}${spanBars(day.admission, scale, 56, "closed")}
    ${ticks(day.landings, scale, 82, "landing")}${ticks(day.trains, scale, 108, "push")}${loadCurve(day.load, scale)}
    <path class="now" d="M${scale.x(now)} 18 V178"/><text class="small nowtext" x="${scale.x(now) + 4}" y="178">now ${clock(now)}</text></svg>`;
}

function partDay(state) {
  const day = dayOf(state);
  const scale = dayScale();
  const span = (s) => `${when(s.from)} to ${s.to ? when(s.to) : "now"}`;
  const episodes = day.episodes.filter((e) => scale.today(e.to || now)).map((e) => `<li>${lamp(e.to ? "dark" : "danger")}<b>${esc(span(e))}</b> main red · ${say(e.ended)}</li>`);
  const closed = day.admission.map((a) => `<li>${lamp(a.to ? "dark" : "caution")}<b>${esc(span(a))}</b> admission closed · ${say(a.why)} ${tag(day.admissionStaged)}</li>`);
  const counts = `${day.landings.filter(scale.today).length} landings and ${day.trains.filter((t) => scale.today(t.at)).length} trains marked today`;
  return `${dayStrip(day)}<ul class="daylist">
    ${episodes.join("") || `<li>${lamp("clear")}No red episode today in the runs of main the board lists.</li>`}
    ${closed.join("") || "<li>No span of closed admission.</li>"}<li class="quiet">${counts}; hover a mark for its sha and time.</li></ul>`;
}

// ---- 5. everything else --------------------------------------------------------------------

function drawer(title, count, one, rows) {
  return `<details class="drawer"><summary><span class="name">${title}</span><b>${count}</b><span class="one">${say(cut(String(one), 110))}</span></summary>
    <ul>${rows.map((row) => `<li>${row}</li>`).join("") || "<li>Nothing to show.</li>"}</ul></details>`;
}

function partRest(state) {
  const metrics = list(state.metrics, "the measures");
  const off = metrics.filter((metric) => ["attention", "failed"].includes(metric.state));
  const roles = list(state.roles);
  const runs = list(state.ci_runs);
  const sessions = list(state.sessions);
  const events = list(state.events, "the events");
  const notes = record(state.board_restarts).notes || [];
  const health = record(state.daily_health).line || "";
  return [
    drawer("Measures", metrics.length, off.length ? `${off.length} off their mark: ${off.map((m) => m.label).join(", ")}` : "all on their mark",
      metrics.map((m) => `${lamp(ASPECT[m.state])}${say(m.label)}: <b>${esc(m.value)} ${esc(m.unit)}</b> <span class="quiet">${say(m.detail)}</span>`)),
    drawer("Roles", roles.length, `${roles.filter((r) => r.live).length} with a live session`,
      roles.map((r) => `${say(r.name)}: ${esc(r.live)} live, ${esc(r.waiting)} waiting`)),
    drawer("Runs of main", runs.length, `${runs.filter((r) => r.conclusion === "success").length} green of the last ${runs.length}`,
      runs.map((r) => `${lamp(r.conclusion === "success" ? "clear" : "danger")}${esc(r.sha)} · ${esc(when(r.started))} · ${esc(r.wall_minutes)} min · ${esc(r.failed_jobs)} failed jobs`)),
    drawer("Sessions", sessions.length, groupBy(sessions, (s) => s.state).map(([name, all]) => `${all.length} ${name}`).join(", "),
      sessions.map((s) => `${say(s.name)} · ${esc(s.state)}${s.work_item ? ` · ${esc(s.work_item)}` : ""}`)),
    drawer("Events", events.length, events[0] ? `latest ${when(events[0].at)} ${events[0].name}` : "none read",
      events.map((e) => `${esc(when(e.at))} · ${esc(e.name)} <span class="quiet">${esc(e.aggregate)}</span>`)),
    drawer("Pipeline health", health ? 1 : 0, health || "no line read", [say(health)]),
    drawer("Board restarts", notes.length, notes[notes.length - 1] || "none today", notes.map(say)),
  ].join("");
}

// ---- the page ------------------------------------------------------------------------------

function alarm(state) {
  const open = dayOf(state).episodes.find((episode) => !episode.to);
  return open ? `<div class="alarm">${lamp("danger")}<b>Main is red</b> since ${esc(when(open.from))} · ${say(open.ended)}</div>` : "";
}

function notice(state) {
  const lines = [];
  if (state.extras.all) lines.push('<p class="stagedday">Staged bad day. Every reading on this page is staged; none is live.</p>');
  if (state.stale) lines.push(`<p>The board's state is ${esc(state.stale_seconds)} s old.</p>`);
  if (state.refresh_error) lines.push(`<p>The board could not refresh: ${say(state.refresh_error)}</p>`);
  groupBy(missing, (pair) => pair[1]).forEach(([why, pairs]) => {
    lines.push(`<p>Not read: ${esc([...new Set(pairs.map((pair) => pair[0]))].join(", "))}. The board says: ${say(why)}.</p>`);
  });
  return lines.join("");
}

function draw(state) {
  now = state.extras.now || Date.now();
  missing = [];
  const parts = { block: partBlock, sidings: partSidings, line: partLine, day: partDay, rest: partRest };
  Object.entries(parts).forEach(([id, part]) => { document.getElementById(id).innerHTML = part(state); });
  document.getElementById("alarm").innerHTML = alarm(state);
  document.getElementById("notice").innerHTML = notice(state);
  document.getElementById("clock").textContent = `read ${when(state.generated_at)}`;
}

// The readings no query answers yet, staged for the real-state view and tagged where drawn.
function stagedForRealState() {
  const back = (minutes) => new Date(Date.now() - minutes * 60000).toISOString();
  return {
    admission: [{ from: back(260), to: back(225), why: "load short" }],
    reviewed: [{ slug: "a-reviewed-work-item", title: "A staged entry: no query says which items are reviewed and not yet landed" }],
  };
}

async function read(day) {
  if (day === "bad") return badDay();
  const response = await fetch("/api/state", { cache: "no-store" });
  const state = await response.json();
  if (!response.ok) throw new Error(state.unknown || `answer ${response.status}`);
  return { ...state, extras: stagedForRealState() };
}

async function refresh(force) {
  const day = new URLSearchParams(location.search).get("day") === "bad" ? "bad" : "real";
  document.querySelectorAll(".switch button").forEach((button) => button.classList.toggle("on", button.dataset.day === day));
  try {
    const state = await read(day);
    const stamp = `${day}:${state.generated_at}`;
    if (!force && (stamp === seen || document.querySelector("main details[open]"))) return;
    seen = stamp;
    draw(state);
  } catch (error) {
    document.getElementById("notice").innerHTML = `<p>The board on :4747 did not answer (${esc(error.message)}). Nothing below is current.</p>`;
  }
}

document.querySelectorAll(".switch button").forEach((button) => button.addEventListener("click", () => {
  history.replaceState(null, "", button.dataset.day === "bad" ? "?day=bad" : location.pathname);
  refresh(true);
}));
refresh(true);
setInterval(refresh, 20000);
