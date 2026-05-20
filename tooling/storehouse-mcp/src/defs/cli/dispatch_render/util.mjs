// dispatch_render/util.mjs
//
// Class : DispatchRenderUtil (functional module)
// Purpose : tiny shared helpers used by the rendering sections —
//           string truncation, first-non-empty line, attribute
//           formatting, and the "unrecognised stdout lines" pass
//           that feeds the raw appendix. Lives in its own module so
//           the composer + section files stay small and the
//           helpers are unit-test-friendly.
//
// Usage :
//   import { truncate, firstNonEmpty, formatAttr, unrecognisedLines }
//     from "./util.mjs";
//
// Extracted from dispatch_render.mjs to keep file sizes under the
// 200-LOC rule (CLAUDE.md).

/** Trim, collapse whitespace, truncate to n chars (ellipsis tail). */
export function truncate(s, n = 100) {
  if (!s) return "";
  const flat = String(s).replace(/\s+/g, " ").trim();
  return flat.length > n ? `${flat.slice(0, n - 1)}…` : flat;
}

/** First non-empty line of text, trimmed. Empty string when none. */
export function firstNonEmpty(text) {
  if (!text) return "";
  for (const ln of String(text).split("\n")) {
    const t = ln.trim();
    if (t) return t;
  }
  return "";
}

/**
 * Format one top-level scalar attribute as `key=value`. Nested
 * arrays/objects are summarised as `[N items]` / `{k1, k2, …}` so
 * the state block stays compact.
 */
export function formatAttr(key, value) {
  if (value === null) return `${key}=null`;
  if (Array.isArray(value)) {
    return `${key}=[${value.length} item${value.length === 1 ? "" : "s"}]`;
  }
  if (typeof value === "object") {
    const keys = Object.keys(value);
    return `${key}={${keys.slice(0, 4).join(", ")}${keys.length > 4 ? ", …" : ""}}`;
  }
  if (typeof value === "string") {
    return `${key}=${JSON.stringify(truncate(value, 60))}`;
  }
  return `${key}=${JSON.stringify(value)}`;
}

/**
 * Pass over stdout and yank the lines the digest parser didn't
 * recognise — used by the raw appendix. Drops :
 *   - recognised log shapes (dispatch / event / cascade / policy /
 *     [claude_tool:…] / [mcp:…])
 *   - trailing JSON state lines (single-line `{…}` that parse)
 *   - blank lines
 *
 * What remains is the "noise" that didn't fit any category — usually
 * `[tts:…]` or `[exec:…]` adapter lines the digest doesn't yet
 * understand. The composer caps + heads the appendix.
 */
export function unrecognisedLines(stdout, _events) {
  if (!stdout) return [];
  const out = [];
  const TS = /^\[[^\]]+\]\s+/;
  const recognised = [
    new RegExp(TS.source + /dispatch\s+\S+#\S+/.source),
    new RegExp(TS.source + /event\s+\S+#\S+/.source),
    new RegExp(TS.source + /cascade\s+\S+#\S+\s+ok=/.source),
    new RegExp(TS.source + /policy\s+\S+\s+on\s+\S+\s+->\s+\S+/.source),
    new RegExp(TS.source + /\[(?:claude_tool|mcp):[^\]]+\]/.source),
  ];
  for (const raw of String(stdout).split("\n")) {
    const line = raw.trimEnd();
    if (!line) continue;
    // Drop trailing JSON state — single-line `{…}` that parses.
    if (line.trim().startsWith("{") && line.trim().endsWith("}")) {
      try { JSON.parse(line.trim()); continue; } catch { /* not JSON */ }
    }
    if (recognised.some((re) => re.test(line))) continue;
    out.push(line);
  }
  return out;
}
