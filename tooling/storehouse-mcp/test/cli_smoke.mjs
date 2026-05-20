// cli_smoke.mjs
//
// End-to-end smoke for the 10 storehouse__<cli> tools and the
// storehouse://events resource. Boots the server via stdio MCP
// transport, lists tools+resources, calls a few tools, subscribes to
// events, writes a line to the JSONL file, asserts the
// notifications/resources/updated frame fires.
//
// Run : `node test/cli_smoke.mjs` from the storehouse-mcp/ dir.
// Exits 0 on green, non-zero on assertion failure.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { writeFileSync, appendFileSync, unlinkSync, existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SERVER = path.join(__dirname, "..", "src", "server.mjs");
const HECKS_ROOT = "/Users/christopheryoung/Projects/hecks";
const WORLD_BLUEBOOK = path.join(
  HECKS_ROOT,
  "hecks_conception/aggregates/world/world.bluebook",
);
const SANDBOX_BEHAVIORS = path.join(
  HECKS_ROOT,
  "hecks_conception/aggregates/sandbox/sandbox.behaviors",
);

let failed = 0;
function ok(label) { process.stderr.write(`ok   ${label}\n`); }
function fail(label, detail) {
  failed++;
  process.stderr.write(`FAIL ${label}: ${detail}\n`);
}
function eq(a, b, label) { a === b ? ok(label) : fail(label, `expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`); }
function truthy(v, label) { v ? ok(label) : fail(label, `expected truthy got ${JSON.stringify(v)}`); }
function contains(haystack, needle, label) {
  haystack && haystack.includes(needle)
    ? ok(label)
    : fail(label, `did not find ${JSON.stringify(needle)} in ${JSON.stringify(haystack)?.slice(0, 200)}`);
}

async function main() {
  // Use a private events file so the test does not collide with the
  // real runtime stream.
  const tmpDir = mkdtempSync(path.join(tmpdir(), "storehouse-mcp-smoke-"));
  const eventsPath = path.join(tmpDir, "events.jsonl");
  writeFileSync(eventsPath, "");

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [SERVER],
    env: {
      ...process.env,
      HECKS_AGENT_EVENT_STREAM: eventsPath,
      STOREHOUSE_BIN: path.join(HECKS_ROOT, "rust/target/release/storehouse"),
    },
  });

  const client = new Client(
    { name: "storehouse-mcp-cli-smoke", version: "0.0.1" },
    { capabilities: {} },
  );
  await client.connect(transport);

  // -- tools/list contains the 10 expected tools
  const list = await client.listTools();
  const names = new Set(list.tools.map((t) => t.name));
  for (const expected of [
    "storehouse__dispatch",
    "storehouse__query",
    "storehouse__state",
    "storehouse__catalog",
    "storehouse__describe_aggregate",
    "storehouse__list_aggregates",
    "storehouse__validate",
    "storehouse__macrophage_check",
    "storehouse__behaviors",
    "storehouse__conceive_behaviors",
  ]) {
    truthy(names.has(expected), `tools/list has ${expected}`);
  }
  // The retired hand-registered tools must NOT come back.
  for (const gone of [
    "storehouse__bash",
    "storehouse__read",
    "storehouse__edit",
    "storehouse__update",
    "storehouse__grep",
    "storehouse__glob",
    "storehouse__web_fetch",
    "storehouse__web_search",
    "storehouse__record_result",
    "storehouse__dispatch_command",
    "storehouse__list",
  ]) {
    truthy(!names.has(gone), `retired tool ${gone} is gone`);
  }

  // -- resources/list returns storehouse://events
  const resources = await client.listResources();
  const uris = resources.resources.map((r) => r.uri);
  truthy(uris.includes("storehouse://events"), "resources/list has storehouse://events");

  // -- storehouse__validate on a known-good bluebook
  const validateRes = await client.callTool({
    name: "storehouse__validate",
    arguments: { bluebook_path: WORLD_BLUEBOOK },
  });
  eq(validateRes.isError, false, "validate isError=false");
  contains(validateRes.content[0].text, "VALID", "validate stdout VALID");

  // -- storehouse__catalog returns the full IR (JSON, pretty-printed)
  const catalogRes = await client.callTool({
    name: "storehouse__catalog",
    arguments: { bluebook_path: WORLD_BLUEBOOK },
  });
  eq(catalogRes.isError, false, "catalog isError=false");
  contains(catalogRes.content[0].text, '"aggregates"', "catalog stdout has aggregates key");
  // pretty-printed JSON has leading spaces (2-space indent)
  truthy(catalogRes.content[0].text.includes("  "), "catalog output is pretty-printed (has indentation)");

  // -- storehouse__describe_aggregate emits one aggregate's IR
  const describeRes = await client.callTool({
    name: "storehouse__describe_aggregate",
    arguments: { bluebook_path: WORLD_BLUEBOOK, aggregate_name: "World" },
  });
  eq(describeRes.isError, false, "describe_aggregate isError=false");
  contains(describeRes.content[0].text, '"name": "World"', "describe_aggregate names World");

  // -- describe_aggregate on a missing name surfaces the available list
  const describeMissRes = await client.callTool({
    name: "storehouse__describe_aggregate",
    arguments: { bluebook_path: WORLD_BLUEBOOK, aggregate_name: "DoesNotExist" },
  });
  eq(describeMissRes.isError, true, "describe_aggregate miss isError=true");
  contains(describeMissRes.content[0].text, "available", "describe_aggregate miss lists available names");

  // -- storehouse__list_aggregates (parse) returns World
  const listAggRes = await client.callTool({
    name: "storehouse__list_aggregates",
    arguments: { bluebook_path: WORLD_BLUEBOOK },
  });
  eq(listAggRes.isError, false, "list_aggregates isError=false");
  contains(listAggRes.content[0].text, "World", "list_aggregates mentions World");

  // -- storehouse__query rejects a PascalCase verb (command-shape)
  const queryShapeRes = await client.callTool({
    name: "storehouse__query",
    arguments: {
      aggregates_dir: path.join(HECKS_ROOT, "hecks_conception"),
      verb: "Tools::ShellTool.Bash",
      summary: "intentionally wrong shape to test query verb guard",
    },
  });
  eq(queryShapeRes.isError, true, "query rejects command-shape verb");
  contains(queryShapeRes.content[0].text, "looks like a command", "query shape error mentions command");

  // -- storehouse__dispatch without summary must be rejected (i606)
  const dispatchNoSummaryRes = await client.callTool({
    name: "storehouse__dispatch",
    arguments: {
      aggregates_dir: path.join(HECKS_ROOT, "hecks_conception"),
      command: "Tools::ShellTool.Bash",
      args: { id: "cli-smoke-no-summary", shell_command: "echo nope" },
      summary: "",
    },
  });
  eq(dispatchNoSummaryRes.isError, true, "dispatch without summary isError=true");
  contains(dispatchNoSummaryRes.content[0].text, "summary is required", "dispatch no-summary error mentions 'summary is required'");

  // -- storehouse__dispatch — universal door. Dispatch ShellTool.Bash
  // and assert ok=true + state carries the captured shell command.
  const dispatchRes = await client.callTool({
    name: "storehouse__dispatch",
    arguments: {
      aggregates_dir: path.join(HECKS_ROOT, "hecks_conception"),
      command: "Tools::ShellTool.Bash",
      args: { id: "cli-smoke-bash", shell_command: "echo smoke", description: "cli smoke" },
      summary: "cli smoke dispatch for storehouse-mcp test",
    },
  });
  eq(dispatchRes.isError, false, "dispatch ShellTool.Bash isError=false");
  contains(dispatchRes.content[0].text, '"ok":true', "dispatch stdout ok=true");

  // -- structuredContent.events — parsed event array from stdout
  const dispatchStruct = dispatchRes.structuredContent || {};
  truthy(Array.isArray(dispatchStruct.events), "dispatch carries events[] array");
  truthy((dispatchStruct.events || []).length >= 1, "dispatch events[] non-empty");
  const firstEv = (dispatchStruct.events || [])[0] || {};
  eq(firstEv.kind, "dispatch", "events[0].kind === dispatch");
  truthy(typeof firstEv.invocation_id === "string" && firstEv.invocation_id.length > 0,
    "events[0].invocation_id is a non-empty string");
  // Every parsed event should carry the same invocation_id (chain id)
  const invIds = new Set((dispatchStruct.events || []).map((e) => e.invocation_id));
  eq(invIds.size, 1, "all events share one invocation_id");

  // -- structuredContent.auto_summary — non-empty digest line
  truthy(
    typeof dispatchStruct.auto_summary === "string" && dispatchStruct.auto_summary.length > 0,
    "dispatch carries non-empty auto_summary",
  );
  contains(dispatchStruct.auto_summary, "Tools::ShellTool.Bash", "auto_summary names the verb");
  contains(dispatchStruct.auto_summary, "exit 0", "auto_summary reports exit 0");

  // -- multi-line output renders as real newlines, not escaped \\n (i607)
  const multiLineRes = await client.callTool({
    name: "storehouse__dispatch",
    arguments: {
      aggregates_dir: path.join(HECKS_ROOT, "hecks_conception"),
      command: "Tools::ShellTool.Bash",
      args: { id: "cli-smoke-multiline", shell_command: "printf 'line1\\nline2\\nline3\\n'", description: "multiline test" },
      summary: "verify multi-line stdout renders without escape sequences",
    },
  });
  const multiLineText = multiLineRes.content[0].text;
  const realNewlines = (multiLineText.match(/\n/g) || []).length;
  const escapedNewlines = (multiLineText.match(/\\n/g) || []).length;
  truthy(realNewlines > escapedNewlines, "multi-line output has real newlines, not escaped \\n");

  // -- storehouse__state — read the record we just dispatched by id.
  const stateRes = await client.callTool({
    name: "storehouse__state",
    arguments: {
      aggregates_dir: path.join(HECKS_ROOT, "hecks_conception"),
      aggregate_name: "ShellTool",
      id: "cli-smoke-bash",
      summary: "verify ShellTool record persisted after cli-smoke dispatch",
    },
  });
  eq(stateRes.isError, false, "state read isError=false");
  contains(stateRes.content[0].text, '"ok":true', "state read ok=true");
  contains(stateRes.content[0].text, "echo smoke", "state carries shell_command");

  // -- storehouse__state on a missing id returns ok=false (not error).
  const stateMissRes = await client.callTool({
    name: "storehouse__state",
    arguments: {
      aggregates_dir: path.join(HECKS_ROOT, "hecks_conception"),
      aggregate_name: "ShellTool",
      id: "no-such-id-cli-smoke",
      summary: "confirm missing id returns ok=false gracefully",
    },
  });
  eq(stateMissRes.isError, false, "state miss isError=false (ok answer)");
  contains(stateMissRes.content[0].text, '"ok":false', "state miss ok=false");

  // -- storehouse__macrophage_check on a non-bluebook surfaces a complaint
  const macroRes = await client.callTool({
    name: "storehouse__macrophage_check",
    arguments: { bluebook_path: "/tmp/not-a-bluebook.rs" },
  });
  truthy(macroRes.content[0].text.length > 0, "macrophage_check returned output");

  // -- storehouse__behaviors on the sandbox behaviors file
  if (existsSync(SANDBOX_BEHAVIORS)) {
    const behaviorsRes = await client.callTool({
      name: "storehouse__behaviors",
      arguments: { behaviors_path: SANDBOX_BEHAVIORS },
    });
    contains(behaviorsRes.content[0].text, "passed", "behaviors output mentions 'passed'");
  } else {
    process.stderr.write(`skip behaviors (no sandbox.behaviors)\n`);
  }

  // -- events resource read returns the file contents
  const eventsRead = await client.readResource({ uri: "storehouse://events" });
  eq(eventsRead.contents[0].uri, "storehouse://events", "events read uri");
  eq(eventsRead.contents[0].text, "", "events file initially empty");

  // -- subscribe + write a line → expect a notifications/resources/updated
  let notifyFired = false;
  client.setNotificationHandler(
    (await import("@modelcontextprotocol/sdk/types.js")).ResourceUpdatedNotificationSchema,
    async (msg) => {
      if (msg.params?.uri === "storehouse://events") notifyFired = true;
    },
  );
  await client.subscribeResource({ uri: "storehouse://events" });

  // Give the watcher a beat to attach, then append a synthetic event.
  await new Promise((r) => setTimeout(r, 200));
  appendFileSync(eventsPath, JSON.stringify({ kind: "smoke", at: Date.now() }) + "\n");
  // Wait up to 2s for notification.
  for (let i = 0; i < 20 && !notifyFired; i++) {
    await new Promise((r) => setTimeout(r, 100));
  }
  truthy(notifyFired, "events subscribe → resources/updated notification fired");

  // After the notification fires, a re-read should surface the new line.
  const eventsRead2 = await client.readResource({ uri: "storehouse://events" });
  contains(eventsRead2.contents[0].text, '"kind":"smoke"', "events re-read includes new line");

  await client.close();
  try { unlinkSync(eventsPath); } catch {}

  if (failed > 0) {
    process.stderr.write(`\n${failed} smoke check(s) FAILED\n`);
    process.exit(1);
  }
  process.stderr.write("\nall cli smoke checks passed\n");
}

main().catch((err) => {
  process.stderr.write(`cli smoke fatal: ${err.stack || err}\n`);
  process.exit(1);
});
