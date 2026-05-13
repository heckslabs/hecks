#!/usr/bin/env node
// server.mjs
//
// storehouse-mcp — the MCP server that exposes Hecks bluebook dispatches
// as MCP tools. Run by claude-code (via .mcp.json or `claude mcp add`).
//
// Talks stdio MCP transport. Each tool call shells to `storehouse` and
// returns the parsed JSON state object as the response payload.
//
// The universal door is `storehouse__dispatch` — any bluebook command
// (Domain::Aggregate.Command) or query (Domain::Aggregate.snake_case)
// against any aggregates root. Discovery flows through
// storehouse__list_aggregates, storehouse__describe_aggregate, and
// storehouse__catalog. No per-command MCP tools are hand-registered ;
// the LLM constructs the verb string dynamically from the IR catalog.
//
// Env vars :
//   STOREHOUSE_BIN              — path to the storehouse binary (default: "storehouse" on PATH)
//   STOREHOUSE_ROOT             — bluebook root dir (default: "hecks_conception")

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { TOOLS, runTool } from "./tools.mjs";
import { registerEventsResource } from "./events.mjs";

const server = new McpServer(
  {
    name: "storehouse-mcp",
    version: "0.1.0",
  },
  {
    capabilities: {
      tools: {},
      // The events resource backs the i17 emit_to_agent stream ;
      // subscribe → notifications/resources/updated on each new line.
      resources: { subscribe: true, listChanged: false },
    },
    instructions:
      "The Hecks bluebook bus. storehouse__dispatch is the universal door — call any bluebook command (Domain::Aggregate.Command) or query (Domain::Aggregate.snake_case) on any aggregates root. Use storehouse__catalog or storehouse__describe_aggregate first to discover what's callable. storehouse__validate, storehouse__macrophage_check, storehouse__behaviors, and storehouse__conceive_behaviors cover the developer workflow. The storehouse://events resource is a live tail of the runtime's emit_to_agent stream (i17) — subscribe to be notified of policy events as they fire.",
  },
);

registerEventsResource(server);

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
    `[storehouse-mcp] connected, ${TOOLS.length} tools + storehouse://events resource registered\n`,
  );
}

main().catch((err) => {
  process.stderr.write(`[storehouse-mcp] fatal: ${err.stack || err}\n`);
  process.exit(1);
});
