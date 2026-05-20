// dispatch_digest.mjs
//
// Class : DispatchDigest (functional module)
// Purpose : turn a storehouse CLI stdout/stderr stream into a structured
//           events[] array + a one-line auto_summary, so the MCP caller
//           (Chris) can read what happened without squinting at raw JSON.
// Usage :
//   import { parseEvents, composeAutoSummary } from "./dispatch_digest.mjs";
//   const events = parseEvents(stdout);
//   const auto_summary = composeAutoSummary({ command, exit_code, ok, events, stderr });
//
// Five line shapes are recognised, taken verbatim from
// rust/src/runtime/storehouse_log.rs (i622) :
//
//   [ts] dispatch <FQN>#<inv_id>[ "description"]
//   [ts] event <Aggregate>.<EventName>#<id>
//   [ts] cascade <FQN>#<id> ok=true|false
//   [ts] policy <PolicyName> on <Aggregate>.<EventName>#<id> -> <Dispatched>
//   [ts] [claude_tool:<tool>] ok=... exit=... ...   (adapter)
//   [ts] [mcp:<server>] ...                          (adapter)
//
// Lines that don't match any shape are skipped silently — that leaves
// the trailing state JSON, raw command output, and any other noise out
// of the digest. invocation_id only appears on the `dispatch` line ;
// every subsequent event carries the most-recent dispatch's
// invocation_id forward until a new dispatch line appears.

const TS = /^\[(?<ts>[^\]]+)\]\s+/;

const DISPATCH_RE = new RegExp(
  TS.source + /dispatch\s+(?<verb>\S+?)#(?<inv>\S+?)(?:\s+"(?<desc>[^"]*)")?\s*$/.source,
);
const EVENT_RE = new RegExp(
  TS.source + /event\s+(?<agg>[^.\s]+)\.(?<evname>[^#\s]+)#(?<id>\S+)\s*$/.source,
);
const CASCADE_RE = new RegExp(
  TS.source + /cascade\s+(?<verb>\S+?)#(?<id>.+?)\s+ok=(?<ok>true|false)\s*$/.source,
);
const POLICY_RE = new RegExp(
  TS.source +
    /policy\s+(?<name>\S+)\s+on\s+(?<agg>[^.\s]+)\.(?<evname>[^#\s]+)#(?<id>\S+)\s+->\s+(?<dispatched>\S+)\s*$/.source,
);
const ADAPTER_RE = new RegExp(
  TS.source + /\[(?<channel>(?:claude_tool|mcp):[^\]]+)\]\s+(?<rest>.*)$/.source,
);

// Parse `key="value"` and `key=value` tokens out of an adapter rest tail.
// Used to lift `ok=`, `exit=`, `error=` off claude_tool adapter lines so
// the digest can spot per-step failures cleanly.
function parseKvTail(rest) {
  const out = {};
  const re = /(\w+)=("(?:[^"\\]|\\.)*"|\S+)/g;
  let m;
  while ((m = re.exec(rest)) !== null) {
    let v = m[2];
    if (v.startsWith('"') && v.endsWith('"')) {
      v = v.slice(1, -1).replace(/\\(.)/g, "$1");
    }
    out[m[1]] = v;
  }
  return out;
}

/**
 * Parse a storehouse stdout stream into a structured events[] array.
 *
 * Each event is { ts, kind, verb, target, invocation_id, ...extras }.
 * - kind : "dispatch" | "event" | "cascade" | "policy" | "adapter"
 * - verb : FQN command for dispatch/cascade ; policy name for policy ;
 *          "<Aggregate>.<EventName>" for event ; adapter channel for adapter
 * - target : "<Aggregate>#<id>" when applicable, else null
 * - invocation_id : the most-recent dispatch's `inv_*` id ; null only
 *                   when no dispatch line preceded the row
 *
 * Unrecognised lines (state JSON, raw output, etc.) are dropped.
 */
export function parseEvents(stdout) {
  const events = [];
  if (!stdout) return events;
  let currentInv = null;
  for (const raw of stdout.split("\n")) {
    const line = raw.trimEnd();
    if (!line) continue;
    let m;
    if ((m = line.match(DISPATCH_RE))) {
      currentInv = m.groups.inv;
      events.push({
        ts: m.groups.ts,
        kind: "dispatch",
        verb: m.groups.verb,
        target: null,
        invocation_id: currentInv,
        ...(m.groups.desc ? { description: m.groups.desc } : {}),
      });
      continue;
    }
    if ((m = line.match(EVENT_RE))) {
      const { ts, agg, evname, id } = m.groups;
      events.push({
        ts,
        kind: "event",
        verb: `${agg}.${evname}`,
        target: `${agg}#${id}`,
        invocation_id: currentInv,
      });
      continue;
    }
    if ((m = line.match(CASCADE_RE))) {
      const { ts, verb, id, ok } = m.groups;
      events.push({
        ts,
        kind: "cascade",
        verb,
        target: `${verb}#${id}`,
        invocation_id: currentInv,
        ok: ok === "true",
      });
      continue;
    }
    if ((m = line.match(POLICY_RE))) {
      const { ts, name, agg, evname, id, dispatched } = m.groups;
      events.push({
        ts,
        kind: "policy",
        verb: name,
        target: `${agg}.${evname}#${id}`,
        invocation_id: currentInv,
        dispatched,
      });
      continue;
    }
    if ((m = line.match(ADAPTER_RE))) {
      const { ts, channel, rest } = m.groups;
      const kv = parseKvTail(rest);
      events.push({
        ts,
        kind: "adapter",
        verb: channel,
        target: null,
        invocation_id: currentInv,
        ...(kv.ok !== undefined ? { ok: kv.ok === "true" } : {}),
        ...(kv.exit !== undefined ? { exit: Number(kv.exit) } : {}),
        ...(kv.error ? { error: kv.error } : {}),
      });
      continue;
    }
    // unrecognised — silently dropped
  }
  return events;
}

// First non-empty line of a text blob, trimmed and truncated to fit the
// auto_summary on a single line. Stderr / dispatch-error tails are
// often multi-line ; the digest only carries the headline.
function firstLine(text, max = 80) {
  if (!text) return "";
  for (const ln of text.split("\n")) {
    const t = ln.trim();
    if (!t) continue;
    return t.length > max ? `${t.slice(0, max - 1)}…` : t;
  }
  return "";
}

/**
 * Compose the auto_summary line.
 *
 * Three shapes :
 *   - success + events :
 *       "<verb> → exit <n>, <N> events (<names>), <M> polic(y/ies) fired"
 *   - success + zero events :
 *       "<verb> → exit <n>, 0 events"
 *   - failure :
 *       "<verb> → exit <n> '<first-line-of-stderr>', no events emitted"
 *   - transport error (no dispatch line at all) :
 *       "<verb> → dispatch did not start: <stderr-first-line>"
 */
export function composeAutoSummary({ command, exit_code, ok, events, stderr }) {
  const verb = command || "<unknown>";
  const dispatched = events.some((e) => e.kind === "dispatch");
  if (!dispatched) {
    const tail = firstLine(stderr) || `exit ${exit_code}`;
    return `${verb} → dispatch did not start: ${tail}`;
  }
  const emitted = events.filter((e) => e.kind === "event");
  const policies = events.filter((e) => e.kind === "policy");
  if (ok === false) {
    const tail = firstLine(stderr);
    const quoted = tail ? ` '${tail}'` : "";
    const eventNote = emitted.length === 0
      ? ", no events emitted"
      : `, ${emitted.length} event${emitted.length === 1 ? "" : "s"} emitted`;
    return `${verb} → exit ${exit_code}${quoted}${eventNote}`;
  }
  if (emitted.length === 0) {
    return `${verb} → exit ${exit_code}, 0 events`;
  }
  const names = emitted.map((e) => e.verb.split(".").slice(-1)[0]).join(", ");
  const polNote = policies.length === 0
    ? "0 policies"
    : policies.length === 1
      ? `1 policy (${policies[0].verb})`
      : `${policies.length} policies`;
  return `${verb} → exit ${exit_code}, ${emitted.length} event${emitted.length === 1 ? "" : "s"} (${names}), ${polNote} fired`;
}
