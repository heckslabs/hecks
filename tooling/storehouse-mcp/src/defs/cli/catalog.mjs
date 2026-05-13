// catalog.mjs — storehouse__catalog → `storehouse dump <bluebook>`
//
// Full canonical-IR JSON for a whole bluebook : every aggregate, every
// command and query, every attribute and value object, plus policies,
// fixtures, and process managers. This is the LLM's index when
// constructing dispatch verbs through storehouse__dispatch.
//
// For one-aggregate focus, use storehouse__describe_aggregate.

import { z } from "zod";
import { runCli, toMcpResponse } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__catalog",
  title: "Full Bluebook Catalog (canonical IR)",
  description:
    "Emit the full canonical-IR JSON for a bluebook — every aggregate, command, query, attribute, value object, policy, fixture, process manager. This is the LLM's index for discovering what storehouse__dispatch can call against the bluebook. Wraps `storehouse dump <bluebook>`.",
  inputSchema: {
    bluebook_path: z
      .string()
      .min(1)
      .describe("Absolute path to a .bluebook file."),
  },
  async run(args) {
    const result = await runCli("dump", [args.bluebook_path]);
    return toMcpResponse(result);
  },
};
