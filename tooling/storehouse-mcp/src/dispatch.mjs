// dispatch.mjs
//
// StorehouseDispatcher — shells to the `storehouse` CLI and returns the
// parsed JSON line (the last `{` ... `}` line on stdout, which is what
// the runtime emits for every Tools.* dispatch).
//
// Usage:
//
//   import { dispatch } from "./dispatch.mjs";
//   const result = await dispatch("Tools.Bash", {
//     id: "abc",
//     shell_command: "echo hi",
//   });
//   // → { aggregate: "Tools", id: "abc", ok: true, state: { ... },
//   //     dispatched_command: "Tools.Bash",
//   //     side_effect: "[claude_tool:bash] ok=true exit=0 ...",
//   //     raw_stdout: "..." }
//
// The dispatcher hides exactly one detail : whether to use the legacy
// short form (`Tools.Bash`) or the fully-qualified form
// (`framework::tools::Tools::Bash`). Toggled by env var
// STOREHOUSE_MCP_QUALIFIED (default false ; the Tools.bluebook split
// hasn't merged to main yet, see the sidequest brief).

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const STOREHOUSE_BIN =
  process.env.STOREHOUSE_BIN || "storehouse";
const QUALIFIED =
  (process.env.STOREHOUSE_MCP_QUALIFIED || "false").toLowerCase() === "true";

// Resolve the storehouse root. Order :
//   1. STOREHOUSE_ROOT env var (absolute or relative to cwd)
//   2. ./hecks_conception relative to cwd
//   3. ../../hecks_conception walking up from this file's directory
//      (handles the case where the MCP runs from tooling/storehouse-mcp/)
function resolveStorehouseRoot() {
  if (process.env.STOREHOUSE_ROOT) {
    return resolve(process.env.STOREHOUSE_ROOT);
  }
  const cwdRoot = resolve(process.cwd(), "hecks_conception");
  if (existsSync(cwdRoot)) return cwdRoot;
  let dir = dirname(fileURLToPath(import.meta.url));
  for (let i = 0; i < 8; i++) {
    const candidate = join(dir, "hecks_conception");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  // Final fallback : let the CLI surface its own error.
  return "hecks_conception";
}

const STOREHOUSE_ROOT = resolveStorehouseRoot();

// Map from the short Tools.X verb to the fully-qualified form. Used
// when the enrichment merges and we flip the flag on.
const QUALIFIED_PATHS = {
  "Tools.Bash":         "framework::tools::ShellTool::Bash",
  "Tools.Read":         "framework::tools::FileTool::Read",
  "Tools.Edit":         "framework::tools::FileTool::Edit",
  "Tools.Update":       "framework::tools::FileTool::Update",
  "Tools.Grep":         "framework::tools::SearchTool::Grep",
  "Tools.Glob":         "framework::tools::SearchTool::Glob",
  "Tools.WebFetch":     "framework::tools::WebTool::WebFetch",
  "Tools.WebSearch":    "framework::tools::WebTool::WebSearch",
  "Tools.RecordResult": "framework::tools::Cascade::RecordResult",
};

function pickPath(verb) {
  if (!QUALIFIED) return verb;
  return QUALIFIED_PATHS[verb] || verb;
}

// Serialize an attribute value to the `key=value` form the storehouse
// CLI expects. Values that contain whitespace are passed as separate
// argv entries (spawn handles quoting), not joined into a single string.
function encodeAttrs(attrs) {
  const args = [];
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null) continue;
    args.push(`${k}=${String(v)}`);
  }
  return args;
}

// Parse the trailing JSON object out of storehouse's stdout. The CLI
// prints zero or more `[claude_tool:...]` side-effect lines first, then
// a single JSON line. We scan from the bottom for the first line that
// parses cleanly.
function parseStorehouseStdout(stdout) {
  const lines = stdout.split("\n").filter((l) => l.trim().length > 0);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line.startsWith("{")) continue;
    try {
      return JSON.parse(line);
    } catch {
      // keep scanning
    }
  }
  return null;
}

// Capture any side-effect lines (the `[claude_tool:...]` traces) so the
// MCP response can surface them to the caller for debugging.
function extractSideEffects(stdout) {
  return stdout
    .split("\n")
    .filter((l) => l.startsWith("[claude_tool:"))
    .join("\n");
}

export async function dispatch(verb, attrs) {
  const args = [STOREHOUSE_ROOT, pickPath(verb), ...encodeAttrs(attrs)];

  return await new Promise((resolve, reject) => {
    const child = spawn(STOREHOUSE_BIN, args, {
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));

    child.on("error", reject);
    child.on("close", (code) => {
      const parsed = parseStorehouseStdout(stdout);
      const sideEffects = extractSideEffects(stdout);
      if (code !== 0 && !parsed) {
        reject(
          new Error(
            `storehouse exit=${code} verb=${verb}\nstderr:\n${stderr}\nstdout:\n${stdout}`,
          ),
        );
        return;
      }
      resolve({
        ...(parsed || {}),
        dispatched_command: verb,
        dispatched_path: pickPath(verb),
        side_effect: sideEffects,
        raw_stdout: stdout,
        raw_stderr: stderr,
        exit_code: code,
      });
    });
  });
}

export const __test__ = {
  parseStorehouseStdout,
  extractSideEffects,
  encodeAttrs,
  pickPath,
};
