// dispatch.mjs — storehouse__dispatch
//             → `storehouse <aggregates_dir> <Verb> k=v ...`
//
// The universal door : dispatch any bluebook command or query against
// any aggregates root. The runtime hydrates the .heki stores under
// aggregates_dir, applies the command, persists, and prints the
// resulting state JSON.
//
// command form examples (fully-qualified Domain::Aggregate.Command for
// commands, Domain::Aggregate.snake_case for queries) :
//   "Sandbox::Session.RecordNote"
//   "Tools::ShellTool.Bash"
//   "PigeonCoop::Coop.AdmitPigeon"
//
// args is a free-form object of key=value attribute pairs. Values are
// stringified and joined as `key=value` on the CLI. The runtime parses
// types according to the bluebook's attribute schema.

import { z } from "zod";
import { spawn } from "node:child_process";
import { parseEvents, composeAutoSummary } from "./dispatch_digest.mjs";
import { renderDispatch } from "./dispatch_render.mjs";
import { warmDispatch } from "./serve_child.mjs";

const STOREHOUSE_BIN = process.env.STOREHOUSE_BIN || "storehouse";
// Warm serve is on by default ; set STOREHOUSE_SERVE=0 to force the
// legacy one-shot spawn (e.g. to A/B the latency or debug the child).
const WARM_SERVE = process.env.STOREHOUSE_SERVE !== "0";

function encodeAttrs(args) {
  const out = [];
  for (const [k, v] of Object.entries(args || {})) {
    if (v === undefined || v === null) continue;
    out.push(`${k}=${String(v)}`);
  }
  return out;
}

function dispatchProcess(aggregatesDir, command, attrArgs) {
  return new Promise((resolve, reject) => {
    const argv = [aggregatesDir, command, ...attrArgs];
    const startedAt = Date.now();
    const child = spawn(STOREHOUSE_BIN, argv, {
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("error", reject);
    child.on("close", (code) => {
      const duration_ms = Date.now() - startedAt;
      const lines = stdout.split("\n").filter((l) => l.trim().length);
      let parsed = null;
      for (let i = lines.length - 1; i >= 0; i--) {
        const ln = lines[i].trim();
        if (!ln.startsWith("{")) continue;
        try {
          parsed = JSON.parse(ln);
          break;
        } catch {
          // keep scanning
        }
      }
      const ok = code === 0 && (parsed?.ok !== false);
      const events = parseEvents(stdout);
      const auto_summary = composeAutoSummary({
        command,
        exit_code: code,
        ok,
        events,
        stderr,
      });
      resolve({
        ok,
        exit_code: code,
        command,
        aggregates_dir: aggregatesDir,
        stdout,
        stderr,
        state: parsed,
        events,
        auto_summary,
        duration_ms,
      });
    });
  });
}

// Try the warm resident DAEMON (over its unix socket) first,
// synthesizing the SAME result envelope dispatchProcess returns so the
// downstream render is identical. The warm reply is just the dispatched
// state JSON (matching the one-shot path's `state` field) ; we wrap it
// with ok / events / auto_summary the same way. Throws on any warm-path
// failure (daemon down, timeout, unparseable reply, handled dispatch
// error) so the caller falls back to the one-shot spawn.
async function warmDispatchEnvelope(aggregatesDir, command, attrArgs) {
  const startedAt = Date.now();
  const parsed = await warmDispatch(aggregatesDir, command, attrArgs);
  const duration_ms = Date.now() - startedAt;
  const ok = parsed?.ok !== false;
  // The warm path doesn't stream the per-cascade log lines the one-shot
  // path scrapes events from ; events come from the structured reply
  // when present, else empty. The state itself is authoritative.
  const events = Array.isArray(parsed?.events) ? parsed.events : [];
  const auto_summary = composeAutoSummary({
    command,
    exit_code: ok ? 0 : 1,
    ok,
    events,
    stderr: "",
  });
  return {
    ok,
    exit_code: ok ? 0 : 1,
    command,
    aggregates_dir: aggregatesDir,
    stdout: JSON.stringify(parsed),
    stderr: "",
    state: parsed,
    events,
    auto_summary,
    duration_ms,
    warm: true,
  };
}

export default {
  name: "storehouse__dispatch",
  title: "Dispatch a Bluebook Command or Query",
  description:
    "The universal door. Dispatch any bluebook command or query against any aggregates root. Shells `storehouse <aggregates_dir> <command> k=v ...`. command is the FQN — PascalCase for commands (e.g. 'Sandbox::Session.RecordNote') or snake_case for queries (e.g. 'World::Hecks.current_state'). args is an object of attribute key/values. Returns the runtime's state JSON in structuredContent.state. Use storehouse__catalog or storehouse__describe_aggregate first to discover what's callable.",
  inputSchema: {
    aggregates_dir: z
      .string()
      .min(1)
      .describe(
        "Absolute path to the aggregates root (e.g. /Users/.../hecks_conception) or a single bluebook file.",
      ),
    command: z
      .string()
      .min(1)
      .describe(
        "Fully-qualified verb — Domain::Aggregate.Command for commands, Domain::Aggregate.snake_case for queries.",
      ),
    args: z
      .record(z.any())
      .optional()
      .describe(
        "Key/value pairs for the command's attributes. Values are stringified to key=value on the CLI.",
      ),
    summary: z
      .string()
      .min(1, "summary is required")
      .describe(
        "One-line, terse summary of what this dispatch DOES — e.g., 'write i606 card for MCP summary-required lock' or 'merge sq/macrophage-rename-drop-suffix into main'. Recommended ≤80 characters. Required.",
      ),
  },
  async run(input) {
    const trimmedSummary = (input.summary || "").trim();
    if (!trimmedSummary) {
      return {
        content: [{ type: "text", text: "summary is required: provide a one-line description of what this dispatch does (e.g. 'boot sandbox session for smoke test')" }],
        isError: true,
      };
    }
    const attrArgs = encodeAttrs(input.args || {});
    // Warm-first with graceful degradation. The resident DAEMON answers
    // over its unix socket in single-digit ms ; on ANY failure (daemon
    // down, timeout, unparseable reply, handled dispatch error) we fall
    // back to the one-shot spawn so a warm-path fault never black-holes
    // a dispatch — this is the universal door.
    let result;
    if (WARM_SERVE) {
      try {
        result = await warmDispatchEnvelope(input.aggregates_dir, input.command, attrArgs);
      } catch (err) {
        process.stderr.write(
          `[storehouse__dispatch] warm serve failed (${err && err.message ? err.message : err}); falling back to one-shot spawn\n`,
        );
        result = await dispatchProcess(input.aggregates_dir, input.command, attrArgs);
      }
    } else {
      result = await dispatchProcess(input.aggregates_dir, input.command, attrArgs);
    }
    // Rich rendering for content[0].text — headline, timeline, state,
    // auto-summary. If anything in the renderer throws, fall back to
    // the raw stdout/stderr so a render bug never costs the operator
    // the breadcrumb. The structuredContent stays byte-identical
    // either way.
    let outputText;
    try {
      outputText = renderDispatch(result);
    } catch (err) {
      outputText =
        (result.stdout || result.stderr || `exit=${result.exit_code}`) +
        `\n\n[render error : ${err && err.message ? err.message : err}]`;
    }
    // NOTE: we deliberately do NOT return structuredContent here. When a
    // tool returns structuredContent, the Claude Code conversation surfaces
    // that raw JSON object instead of content[0].text — burying the rich,
    // scannable render (headline · exit · events · ms, timeline, state)
    // under an unreadable JSON blob. Chris wants the summary + elapsed, not
    // the JSON. content[0].text (renderDispatch) IS the human view ; it
    // carries the State + Raw sections too, so nothing machine-readable is
    // lost to the eye. No other consumer reads this tool's structuredContent.
    return {
      content: [{ type: "text", text: outputText }],
      isError: result.ok === false,
    };
  },
};
