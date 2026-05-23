// dispatch_render.mjs
//
// Class : DispatchRender (functional module)
// Purpose : turn a storehouse dispatch result — the structured object
//           assembled by dispatch.mjs (events[], auto_summary, state,
//           stdout, stderr, exit_code, ok, duration_ms) — into the
//           rich, scannable user-facing block that lands in
//           content[0].text. The MCP client renders it as text ; no
//           ANSI colors (they'd display as literal escapes). Unicode
//           box-drawing only.
//
// Usage :
//   import { renderDispatch } from "./dispatch_render.mjs";
//   const text = renderDispatch(result);
//
// Output sections, in order :
//   1. Headline — icon, verb, exit, duration, event count, adapter
//      mark. LOUDEST element.
//   2. Failure block — only when ok=false. stderr + adapter cause.
//   3. Timeline tree — invocation chains in box-drawing form.
//   4. State block — flat post-state attribute list.
//   5. Tool output — the actual stdout/result payload of each
//      claude_tool:* / mcp:* adapter call (so a bus-dispatched
//      ShellTool.Bash / SearchTool.Grep / FileTool.Read returns its
//      OUTPUT to the agent, not just the echoed command state).
//   6. Auto-summary — digest one-liner as TL;DR (leading `—`).
//   7. Raw appendix — unparsed stdout (e.g. [tts:…] lines).
//
// Section renderers + helpers are split into sibling modules to
// honour the 200-LOC rule (CLAUDE.md). This file owns the composer
// and the small sections that didn't justify their own module.
// See docs/dispatch_rendering.md for sample renderings.

import { renderTimeline } from "./dispatch_render/timeline.mjs";
import { truncate, firstNonEmpty, formatAttr, unrecognisedLines } from "./dispatch_render/util.mjs";

const ICON_OK    = "✓";
const ICON_FAIL  = "✗";
const ICON_WARN  = "⚠";
const ICON_PHONE = "📞";

// ----- section : headline --------------------------------------------

function renderHeadline(result) {
  const events = Array.isArray(result.events) ? result.events : [];
  const emitted   = events.filter((e) => e.kind === "event");
  const policies  = events.filter((e) => e.kind === "policy");
  const adapters  = events.filter((e) => e.kind === "adapter");
  const cascades  = events.filter((e) => e.kind === "cascade");
  const icon =
    result.ok === false ? ICON_FAIL
    : result.exit_code !== 0 ? ICON_WARN
    : ICON_OK;
  const verb = result.command || "<unknown verb>";
  const pieces = [`exit ${result.exit_code}`];
  pieces.push(`${emitted.length} event${emitted.length === 1 ? "" : "s"}`);
  if (policies.length > 0) {
    pieces.push(`${policies.length} polic${policies.length === 1 ? "y" : "ies"}`);
  }
  if (adapters.length > 0) pieces.push(`${adapters.length} adapter`);
  if (cascades.length > 0) pieces.push(`${cascades.length} cascade`);
  if (typeof result.duration_ms === "number") pieces.push(`${result.duration_ms} ms`);
  return `${icon} ${verb} · ${pieces.join(" · ")}`;
}

// ----- section : failure block ---------------------------------------

function renderFailure(result) {
  if (result.ok !== false) return null;
  const lines = [`${ICON_FAIL} dispatch failed`];
  const stderrTail = firstNonEmpty(result.stderr);
  if (stderrTail) lines.push(`  stderr : ${truncate(stderrTail, 180)}`);
  const state = result.state || {};
  if (state.error) lines.push(`  error  : ${truncate(state.error, 180)}`);
  const events = Array.isArray(result.events) ? result.events : [];
  const failedAdapter = events.find((e) => e.kind === "adapter" && e.ok === false);
  if (failedAdapter) {
    const err = failedAdapter.error || "(no error message)";
    lines.push(`  ${ICON_PHONE} ${failedAdapter.verb} failed : ${truncate(err, 160)}`);
  }
  // Fallback when no concrete cause was captured — show stdout
  // headline so the user sees SOMETHING, not just "failed".
  if (!stderrTail && !state.error && !failedAdapter) {
    const tail = firstNonEmpty(result.stdout);
    if (tail) lines.push(`  stdout : ${truncate(tail, 180)}`);
  }
  return lines.join("\n");
}

// ----- section : state -----------------------------------------------

function renderState(result) {
  const state = result.state;
  if (!state || typeof state !== "object") return null;
  // Find the first nested aggregate snapshot (post-state). The
  // runtime's trailing JSON typically nests the actual record under
  // an Aggregate-name key alongside top-level ok/error.
  let snapshot = state;
  let aggregateName = null;
  for (const [k, v] of Object.entries(state)) {
    if (k === "ok" || k === "error") continue;
    if (v && typeof v === "object" && !Array.isArray(v)) {
      snapshot = v;
      aggregateName = k;
      break;
    }
  }
  if (snapshot === state) {
    const scalars = Object.entries(state).filter(
      ([k, v]) => k !== "ok" && k !== "error" && (v === null || typeof v !== "object"),
    );
    if (scalars.length === 0) return null;
    return ["State", ...scalars.map(([k, v]) => `  ${formatAttr(k, v)}`)].join("\n");
  }
  const entries = Object.entries(snapshot);
  if (entries.length === 0) return null;
  return [`State (${aggregateName})`, ...entries.map(([k, v]) => `  ${formatAttr(k, v)}`)].join("\n");
}

// ----- section : tool output -----------------------------------------
//
// Each adapter event (claude_tool:* / mcp:*) carrying a non-empty
// `output` is rendered under its channel label. `output` is a real
// multi-line string (the digest unescapes \n) ; lines indent to nest
// under the header. Capped at 200 lines / 8 KB — generous for grep/read
// results, unlike the Raw appendix's 12-line noise cap.

const TOOL_OUTPUT_MAX_LINES = 200;
const TOOL_OUTPUT_MAX_CHARS = 8192;

function renderToolOutput(result) {
  const events = Array.isArray(result.events) ? result.events : [];
  const withOutput = events.filter(
    (e) => e.kind === "adapter" && typeof e.output === "string" && e.output.length > 0,
  );
  if (withOutput.length === 0) return null;
  const out = ["Tool output"];
  for (const ev of withOutput) {
    out.push(`  ${ev.verb}`);
    const body = ev.output.slice(0, TOOL_OUTPUT_MAX_CHARS);
    const lines = body.split("\n");
    const capped = lines.slice(0, TOOL_OUTPUT_MAX_LINES);
    for (const ln of capped) out.push(`    ${ln}`);
    const more = lines.length - capped.length;
    if (more > 0) out.push(`    … (+${more} more line${more === 1 ? "" : "s"})`);
  }
  return out.join("\n");
}

// ----- section : raw appendix ----------------------------------------

function renderRaw(result) {
  const lines = unrecognisedLines(result.stdout, result.events || []);
  if (lines.length === 0) return null;
  const capped = lines.slice(0, 12);
  const more = lines.length - capped.length;
  const out = ["Raw output", ...capped.map((ln) => `  ${truncate(ln, 200)}`)];
  if (more > 0) out.push(`  … (+${more} more line${more === 1 ? "" : "s"})`);
  return out.join("\n");
}

// ----- composer ------------------------------------------------------

/**
 * Compose the full rendering. Public entry point. result is the
 * object dispatch.mjs builds — { ok, exit_code, command, stdout,
 * stderr, state, events, auto_summary, duration_ms }.
 *
 * Returns a string ready to ship as content[0].text.
 */
export function renderDispatch(result) {
  if (!result || typeof result !== "object") return "(no dispatch result)";
  const sections = [renderHeadline(result)];
  const failure = renderFailure(result);
  if (failure) sections.push(failure);
  const timeline = renderTimeline(result.events);
  if (timeline) sections.push(timeline);
  const state = renderState(result);
  if (state) sections.push(state);
  const toolOutput = renderToolOutput(result);
  if (toolOutput) sections.push(toolOutput);
  const raw = renderRaw(result);
  if (raw) sections.push(raw);
  if (result.auto_summary) sections.push(`— ${result.auto_summary}`);
  return sections.join("\n\n");
}

// Internal helpers exposed for the renderer-only unit test. Not part
// of the public dispatch surface.
export const __internals = {
  renderHeadline,
  renderFailure,
  renderState,
  renderToolOutput,
  renderRaw,
};
