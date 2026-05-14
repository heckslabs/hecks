// query.mjs — storehouse__query
//          → `storehouse query <root-or-bluebook> <verb> k=v ...`
//
// Read-only counterpart to storehouse__dispatch. Same dispatch pipeline
// under the hood — the runtime auto-detects query vs. command via the
// bluebook's lexicon. The Rust CLI's `query` subcommand enforces the
// query shape: verb must be Domain::Aggregate.snake_case (lowercase
// first letter after the dot). PascalCase verbs are rejected with a
// pointer back at storehouse__dispatch.
//
// Returns whatever the query resolver produces (typically a JSON value
// or a plain-text scalar, depending on the query).

import { z } from "zod";
import { spawn } from "node:child_process";

const STOREHOUSE_BIN = process.env.STOREHOUSE_BIN || "storehouse";

function encodeAttrs(obj) {
  const out = [];
  for (const [k, v] of Object.entries(obj || {})) {
    if (v === undefined || v === null) continue;
    out.push(`${k}=${String(v)}`);
  }
  return out;
}

function runQuery(root, verb, attrArgs) {
  return new Promise((resolve, reject) => {
    const argv = ["query", root, verb, ...attrArgs];
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
      resolve({
        ok: code === 0,
        exit_code: code,
        root,
        verb,
        stdout,
        stderr,
      });
    });
  });
}

export default {
  name: "storehouse__query",
  title: "Dispatch a Query (read-only)",
  description:
    "Dispatch a query against an aggregates root. Read-only — the runtime resolves the query and prints the result. Shells `storehouse query <root> <Domain::Aggregate.snake_case> k=v ...`. The verb-tail must be snake_case (commands use storehouse__dispatch). Use storehouse__catalog or storehouse__describe_aggregate to discover query names.",
  inputSchema: {
    aggregates_dir: z
      .string()
      .min(1)
      .describe(
        "Absolute path to the aggregates root or a single bluebook file.",
      ),
    verb: z
      .string()
      .min(1)
      .describe(
        "Fully-qualified query verb — Domain::Aggregate.snake_case (lowercase first letter after the dot).",
      ),
    args: z
      .record(z.any())
      .optional()
      .describe(
        "Key/value pairs for the query's input parameters. Values are stringified to key=value on the CLI.",
      ),
    summary: z
      .string()
      .min(1)
      .describe(
        "One-line, terse summary of what this query DOES — e.g., 'check current world state before seeding'. Recommended ≤80 characters. Required.",
      ),
  },
  async run(input) {
    const trimmedSummary = (input.summary || "").trim();
    if (!trimmedSummary) {
      return {
        content: [{ type: "text", text: "summary is required: provide a one-line description of what this query does (e.g. 'fetch current session state')" }],
        isError: true,
      };
    }
    const attrArgs = encodeAttrs(input.args || {});
    const result = await runQuery(input.aggregates_dir, input.verb, attrArgs);
    const outputText = result.stdout || result.stderr || `exit=${result.exit_code}`;
    return {
      content: [{ type: "text", text: outputText }],
      structuredContent: { ...result, summary: trimmedSummary },
      isError: !result.ok,
    };
  },
};
