// cli_dispatch.mjs
//
// StorehouseCliRunner — sibling of dispatch.mjs.
//
// dispatch.mjs shells `storehouse <root> <Verb> k=v ...` (the bus
// dispatcher form, used by Tools.* tools).
//
// cli_dispatch.mjs shells `storehouse <subcommand> <bluebook-path> [args...]`
// (the developer CLI form, used by validate / list / macrophage / behaviors
// / conceive / dispatch_command).
//
// Returns a uniform shape :
//   { ok: bool, exit_code: int, stdout: string, stderr: string,
//     subcommand: string, args: [...] }
//
// Env vars :
//   STOREHOUSE_BIN  — path to the storehouse binary (default: "storehouse")
//
// Usage :
//   import { runCli } from "./cli_dispatch.mjs";
//   const r = await runCli("validate", ["/path/to/foo.bluebook"]);
//   // → { ok: true, exit_code: 0, stdout: "VALID — Foo (1 aggregates)\n", ... }

import { spawn } from "node:child_process";

const STOREHOUSE_BIN = process.env.STOREHOUSE_BIN || "storehouse";

export async function runCli(subcommand, args = [], opts = {}) {
  const fullArgs = [subcommand, ...args];
  return await new Promise((resolve, reject) => {
    const child = spawn(STOREHOUSE_BIN, fullArgs, {
      env: { ...process.env, ...(opts.env || {}) },
      stdio: opts.stdin ? ["pipe", "pipe", "pipe"] : ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));

    if (opts.stdin) {
      child.stdin.write(opts.stdin);
      child.stdin.end();
    }

    child.on("error", reject);
    child.on("close", (code) => {
      resolve({
        ok: code === 0,
        exit_code: code,
        stdout,
        stderr,
        subcommand,
        args: fullArgs,
      });
    });
  });
}

// Helper : wrap a runCli result into the MCP tool response envelope. Used
// by every storehouse__<cli-tool> def so they share one format.
export function toMcpResponse(result) {
  const summary = result.stdout || result.stderr || `exit=${result.exit_code}`;
  return {
    content: [
      {
        type: "text",
        text: summary,
      },
    ],
    structuredContent: result,
    isError: result.ok === false,
  };
}

// Like toMcpResponse but attempts to parse the stdout as JSON and
// re-emit it with 2-space indentation. Used for discovery tools
// (catalog, describe_aggregate) that return structured data — makes
// the response readable in the MCP inspector and downstream renderers.
// Falls back to raw stdout if parsing fails (e.g. error messages).
export function toMcpResponsePretty(result) {
  let text = result.stdout || result.stderr || `exit=${result.exit_code}`;
  if (result.stdout) {
    try {
      const parsed = JSON.parse(result.stdout.trim());
      text = JSON.stringify(parsed, null, 2);
    } catch {
      // not valid JSON (e.g. error output) — fall through to raw text
    }
  }
  return {
    content: [
      {
        type: "text",
        text,
      },
    ],
    structuredContent: result,
    isError: result.ok === false,
  };
}
