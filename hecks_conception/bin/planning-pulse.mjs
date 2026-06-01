// planning-pulse.mjs — the turn-end pulse adapter (story: turn-pulse).
//
// [antibody-exempt: bin/planning-pulse.mjs - the impure hook executor for
//  the "Planning pushes a turn-end pulse" concept. The bluebook part is
//  Plan::Story.ListAll (the query) ; this Node script is the surface
//  glue the UserPromptSubmit hook runs: it queries the board and formats
//  it for additionalContext. Kernel-adjacent hook bridge, like inbox_poll.]
import { execSync } from "node:child_process";
const B = "/Users/christopheryoung/Projects/hecks/rust/target/release/storehouse";
const R = "/Users/christopheryoung/Projects/hecks/hecks_conception/aggregates/plan";
let out;
try { out = execSync(`${B} query ${R} Plan::Story.board`, { encoding: "utf8", timeout: 8000 }); }
catch (e) { process.exit(0); }
let j; try { j = JSON.parse(out); } catch (e) { process.exit(0); }
const s = Array.isArray(j.state) ? j.state : [];
if (!s.length) process.exit(0);
const c = {}; for (const x of s) { const st = x.state || "?"; c[st] = (c[st] || 0) + 1; }
const trunc = (t) => { t = t || ""; return t.length > 30 ? t.slice(0, 29) + "…" : t; };

// task-completion-state (sprint 14) : Task is now its own aggregate. Read
// every Task record via the heki store + bucket by Story ref so each row can
// carry a done/total annotation. Goes through the heki path because the
// `for_story` query requires a story filter ; the only other listing query
// (`pending`) drops done tasks, which the total/done column needs.
let tasksByStory = {};
try {
  const tout = execSync(`${B} heki read ${R}/.heki/plan/task.heki`, { encoding: "utf8", timeout: 8000 });
  const tj = JSON.parse(tout);
  for (const k of Object.keys(tj)) {
    const t = tj[k];
    if (!t || typeof t !== "object") continue;
    const sref = t.story || "";
    if (!sref) continue;
    (tasksByStory[sref] = tasksByStory[sref] || { done: 0, total: 0 });
    tasksByStory[sref].total += 1;
    if (t.status === "done") tasksByStory[sref].done += 1;
  }
} catch (e) { /* no Task store yet — fall open */ }
const taskTag = (ref) => {
  const tc = tasksByStory[ref];
  if (!tc || tc.total === 0) return "";
  return ` [${tc.done}/${tc.total}]`;
};

const withTitle = (st) => s.filter(x => x.state === st).map(x => `${x.ref}${taskTag(x.ref)} ${trunc(x.title)}`);
const lines = ["planning pulse — on the board:"];
const started = withTitle("started"); if (started.length) lines.push("  started ▸ " + started.join(" · "));
const ready = withTitle("ready_for_review"); if (ready.length) lines.push("  ready ▸ " + ready.join(" · "));
// lifecycle-tasked-state (sprint 14) : pre-Start splits into untasked (no tasks yet)
// vs tasked (operator has flipped Tasked, Start is the only outstanding signal).
// Both surface in the queued region of the pulse — callers can see what is awaiting tasking
// and what is awaiting Start.
const tasked = s.filter(x => x.state === "tasked").map(x => x.ref); if (tasked.length) lines.push("  tasked ▸ " + tasked.join(" · "));
const untasked = s.filter(x => x.state === "untasked").map(x => x.ref); if (untasked.length) lines.push("  untasked ▸ " + untasked.join(" · "));
const order = ["done", "started", "ready_for_review", "tasked", "untasked", "deferred"];
lines.push("  ── " + order.filter(k => c[k]).map(k => `${c[k]} ${k}`).join(" · "));
process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: lines.join("\n") } }));
