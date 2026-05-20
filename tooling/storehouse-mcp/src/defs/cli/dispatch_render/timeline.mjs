// dispatch_render/timeline.mjs
//
// Class : DispatchRenderTimeline (functional module)
// Purpose : the timeline tree section of the rich dispatch rendering.
//           Groups parsed events by invocation_id (each `dispatch`
//           line opens a new chain ; subsequent events/policies/
//           cascades/adapters hang under that chain). Renders each
//           group as a box-drawing tree.
//
// Usage :
//   import { renderTimeline } from "./dispatch_render/timeline.mjs";
//   const block = renderTimeline(events);
//   // null when events[] is empty ; multi-line string otherwise.
//
// Symbols :
//   ├ │ └ ─   tree branching
//   ⇢         policy → dispatched arrow
//   📞        adapter call
//   ✓ / ✗     adapter / cascade outcome marks
//
// Extracted from dispatch_render.mjs to keep that file under the
// 200-LOC project rule (CLAUDE.md). The composer in
// dispatch_render.mjs is the only caller.

import { truncate } from "./util.mjs";

const ICON_OK    = "✓";
const ICON_FAIL  = "✗";
const ICON_PHONE = "📞";

const BRANCH = "├";
const LEAF   = "└";
const HYPHEN = "─";

function shortVerb(s) {
  // Strip Domain:: prefix so the tree reads cleanly. Keep Aggregate.Verb.
  return s ? String(s).replace(/^[\w]+::/, "") : "";
}

// Group events by invocation_id while preserving the order they were
// parsed. The digest forwards each `dispatch` line's invocation_id to
// every subsequent event until the next dispatch — so groups are the
// natural cascade chains.
function groupByInvocation(events) {
  const groups = [];
  const byInv = new Map();
  for (const ev of events) {
    const inv = ev.invocation_id || "_none";
    if (!byInv.has(inv)) {
      const g = { invocation_id: inv, events: [] };
      groups.push(g);
      byInv.set(inv, g);
    }
    byInv.get(inv).events.push(ev);
  }
  return groups;
}

function renderEventNode(ev) {
  if (ev.kind === "event") {
    const tail = (ev.target || "").split("#").slice(-1)[0];
    return `event ${shortVerb(ev.verb)}#${tail}`;
  }
  if (ev.kind === "policy") {
    return `policy ${ev.verb} ⇢ ${shortVerb(ev.dispatched || "?")}`;
  }
  if (ev.kind === "cascade") {
    const mark = ev.ok ? ICON_OK : ICON_FAIL;
    return `cascade ${mark} ${shortVerb(ev.verb)}`;
  }
  if (ev.kind === "adapter") {
    const mark = ev.ok === false ? ICON_FAIL : ICON_OK;
    const extras = [];
    if (typeof ev.exit === "number") extras.push(`exit=${ev.exit}`);
    if (ev.error) extras.push(`error=${truncate(ev.error, 60)}`);
    return `${ICON_PHONE} ${ev.verb} ${mark}${extras.length ? " " + extras.join(" ") : ""}`;
  }
  return `${ev.kind} ${ev.verb || ""}`;
}

/**
 * Build the timeline section text. Returns null when there are no
 * events, so the composer can skip the section header for empty
 * cases (failed dispatches that never started, for instance).
 */
export function renderTimeline(events) {
  if (!Array.isArray(events) || events.length === 0) return null;
  const groups = groupByInvocation(events);
  const out = ["Timeline"];
  for (let gi = 0; gi < groups.length; gi++) {
    const g = groups[gi];
    const head = g.events.find((e) => e.kind === "dispatch");
    const rest = g.events.filter((e) => e !== head);
    const inv = g.invocation_id && g.invocation_id !== "_none" ? `#${g.invocation_id}` : "";
    out.push(head ? `${shortVerb(head.verb)}${inv}` : `(orphan events)${inv}`);
    for (let i = 0; i < rest.length; i++) {
      const last = i === rest.length - 1;
      const prefix = last ? `${LEAF}${HYPHEN} ` : `${BRANCH}${HYPHEN} `;
      out.push(`${prefix}${renderEventNode(rest[i])}`);
    }
    if (gi < groups.length - 1) out.push("");
  }
  return out.join("\n");
}

// Internals exposed for the renderer-only unit test.
export const __internals = { groupByInvocation, renderEventNode, shortVerb };
