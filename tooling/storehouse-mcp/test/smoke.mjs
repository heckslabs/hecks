// smoke.mjs
//
// End-to-end smoke test that boots the storehouse-mcp server via stdio
// transport and invokes one tool through the MCP protocol, asserting
// the response contains a parsed JSON state object with ok=true.
//
// Run with `node test/smoke.mjs` from the storehouse-mcp/ directory, or
// `npm run smoke`. Exits 0 on green ; non-zero on any assertion failure.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SERVER = path.join(__dirname, "..", "src", "server.mjs");

function eq(a, b, label) {
  if (a !== b) {
    process.stderr.write(
      `FAIL ${label}: expected ${JSON.stringify(b)} got ${JSON.stringify(a)}\n`,
    );
    process.exit(1);
  }
  process.stderr.write(`ok   ${label}\n`);
}

function truthy(v, label) {
  if (!v) {
    process.stderr.write(`FAIL ${label}: expected truthy got ${JSON.stringify(v)}\n`);
    process.exit(1);
  }
  process.stderr.write(`ok   ${label}\n`);
}

async function main() {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [SERVER],
    env: { ...process.env },
  });

  const client = new Client(
    { name: "storehouse-mcp-smoke", version: "0.0.1" },
    { capabilities: {} },
  );

  await client.connect(transport);

  // List tools first — assert all 9 are present.
  const list = await client.listTools();
  const expected = [
    "storehouse__bash",
    "storehouse__read",
    "storehouse__edit",
    "storehouse__update",
    "storehouse__grep",
    "storehouse__glob",
    "storehouse__web_fetch",
    "storehouse__web_search",
    "storehouse__record_result",
  ];
  const got = list.tools.map((t) => t.name).sort();
  eq(got.length, expected.length, "tool count");
  for (const name of expected) {
    truthy(got.includes(name), `registered ${name}`);
  }

  // Dispatch Tools.Bash through the MCP. The bluebook contract is :
  // ok=true on the response, state.shell_command preserved verbatim,
  // state.output containing the echoed text.
  const bashResult = await client.callTool({
    name: "storehouse__bash",
    arguments: {
      id: "smoke-bash-001",
      shell_command: "echo mcp-test",
      description: "smoke probe via storehouse__bash",
    },
  });
  truthy(bashResult.content, "bash content present");
  const bashState = bashResult.structuredContent;
  truthy(bashState, "bash structuredContent present");
  eq(bashState.aggregate, "Tools", "bash aggregate");
  eq(bashState.id, "smoke-bash-001", "bash id");
  eq(bashState.ok, true, "bash dispatch ok");
  eq(bashState.state.shell_command, "echo mcp-test", "bash state.shell_command");
  truthy(
    bashState.state.output && bashState.state.output.includes("mcp-test"),
    "bash state.output captures echo",
  );

  // Dispatch Tools.Read on an actual file to assert the wrapper handles
  // multi-arg attrs correctly.
  const readResult = await client.callTool({
    name: "storehouse__read",
    arguments: {
      id: "smoke-read-001",
      file_path: SERVER,
      description: "smoke probe via storehouse__read",
    },
  });
  const readState = readResult.structuredContent;
  eq(readState.aggregate, "Tools", "read aggregate");
  eq(readState.id, "smoke-read-001", "read id");
  truthy(
    readState.state.output && readState.state.output.includes("storehouse-mcp"),
    "read state.output captures file content",
  );

  // RecordResult — verify the field re-mapping (tool_kind → tool, ok_status → ok)
  // round-trips correctly.
  const recordResult = await client.callTool({
    name: "storehouse__record_result",
    arguments: {
      id: "smoke-record-001",
      tool_kind: "bash",
      output: "smoke output",
      exit_code: 0,
      ok_status: true,
    },
  });
  const recordState = recordResult.structuredContent;
  eq(recordState.aggregate, "Tools", "record aggregate");
  eq(recordState.state.tool_kind, "bash", "record tool_kind preserved");

  await client.close();
  process.stderr.write("\nall smoke checks passed\n");
}

main().catch((err) => {
  process.stderr.write(`smoke fatal: ${err.stack || err}\n`);
  process.exit(1);
});
