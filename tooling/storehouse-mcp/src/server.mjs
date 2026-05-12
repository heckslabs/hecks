#!/usr/bin/env node
// server.mjs
//
// storehouse-mcp — the MCP server that exposes Hecks Tools.* dispatches
// as MCP tools. Run by claude-code (via .mcp.json or `claude mcp add`).
//
// Talks stdio MCP transport. Each tool call shells to `storehouse` and
// returns the parsed JSON state object as the response payload.
//
// Env vars :
//   STOREHOUSE_BIN              — path to the storehouse binary (default: "storehouse" on PATH)
//   STOREHOUSE_ROOT             — bluebook root dir (default: "hecks_conception")
//   STOREHOUSE_MCP_QUALIFIED    — "true" to use fully-qualified verbs (default: "false")
//
// The qualified flag is the switch for when the Tools.bluebook 5-aggregate
// split (worktree-agent-a2c393f2905d4dfd1) merges to main ; until then
// the legacy short form (Tools.Bash) is what the runtime accepts.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { TOOLS, runTool } from "./tools.mjs";

const server = new McpServer(
  {
    name: "storehouse-mcp",
    version: "0.1.0",
  },
  {
    capabilities: { tools: {} },
    instructions:
      "All filesystem and shell access flows through Tools.* dispatches on the Hecks bus. Every tool call emits a domain event the runtime can react to. Use these in place of native Bash / Read / Edit / Write / Grep / Glob — those are denied at the project layer.",
  },
);

for (const tool of TOOLS) {
  server.registerTool(
    tool.name,
    {
      title: tool.title,
      description: tool.description,
      inputSchema: tool.inputSchema,
    },
    async (args) => runTool(tool.name, args),
  );
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // stderr-log so the user can see the server is alive in claude's MCP
  // diagnostics ; stdout is reserved for the MCP transport.
  process.stderr.write(
    `[storehouse-mcp] connected, ${TOOLS.length} tools registered\n`,
  );
}

main().catch((err) => {
  process.stderr.write(`[storehouse-mcp] fatal: ${err.stack || err}\n`);
  process.exit(1);
});
