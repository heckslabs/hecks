// behaviors.mjs — storehouse__behaviors → `storehouse behaviors <path>`
//
// Runs a *_behavioral_tests.bluebook (or *.behaviors) file against a
// fresh BehaviorRuntime and reports pass/fail/errored counts.

import { z } from "zod";
import { runCli, toMcpResponse } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__behaviors",
  title: "Run a Behaviors File",
  description:
    "Run all behaviors in a *.behaviors or *_behavioral_tests.bluebook file. Wraps `storehouse behaviors <path>`. stdout contains one ✓/✗ line per test plus a totals summary.",
  inputSchema: {
    behaviors_path: z
      .string()
      .min(1)
      .describe("Absolute path to a .behaviors file."),
  },
  async run(args) {
    const result = await runCli("behaviors", [args.behaviors_path]);
    return toMcpResponse(result);
  },
};
