// tools.mjs
//
// Tool registry index + runner. Every storehouse__* tool is a thin
// wrapper around a `storehouse` CLI subcommand ; each def lives in
// its own file under ./defs/cli/ to keep file sizes small. This file
// collects them and provides the runTool helper the server uses.
//
// The MCP surface is intentionally tiny : one universal dispatcher
// (storehouse__dispatch) plus discovery + maintenance tools. The LLM
// constructs the verb string dynamically from the IR catalog ; there
// is no per-bluebook-command hand registration.

import dispatch from "./defs/cli/dispatch.mjs";
import query from "./defs/cli/query.mjs";
import state from "./defs/cli/state.mjs";
import catalog from "./defs/cli/catalog.mjs";
import describeAggregate from "./defs/cli/describe_aggregate.mjs";
import listAggregates from "./defs/cli/list_aggregates.mjs";
import validate from "./defs/cli/validate.mjs";
import macrophageCheck from "./defs/cli/macrophage_check.mjs";
import behaviors from "./defs/cli/behaviors.mjs";
import conceiveBehaviors from "./defs/cli/conceive_behaviors.mjs";

export const TOOLS = [
  // Dispatch — the universal door.
  dispatch,
  query,
  // Read-only state probes.
  state,
  // Discovery — IR catalog at three zoom levels.
  catalog,
  describeAggregate,
  listAggregates,
  // Developer workflow.
  validate,
  macrophageCheck,
  behaviors,
  conceiveBehaviors,
];

// Run a tool by name with caller-supplied args. Every def carries its
// own async run(args) and returns the MCP response envelope directly.
export async function runTool(name, args) {
  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) throw new Error(`unknown tool: ${name}`);
  return await tool.run(args);
}
