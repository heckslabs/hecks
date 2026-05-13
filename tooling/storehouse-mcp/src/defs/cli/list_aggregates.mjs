// list_aggregates.mjs — storehouse__list_aggregates
//                    → `storehouse parse <bluebook-path>` filtered to aggregate names.
//
// We use `parse` rather than `list` because parse emits the structural
// summary in a stable form ; for the MVP the caller just wants the
// aggregate names. The full `list` is exposed by storehouse__list.

import { z } from "zod";
import { runCli, toMcpResponse } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__list_aggregates",
  title: "List Aggregates in a Bluebook",
  description:
    "List the aggregates defined in a bluebook file. Wraps `storehouse parse <bluebook>`. Use as a discovery probe before dispatch_command.",
  inputSchema: {
    bluebook_path: z
      .string()
      .min(1)
      .describe("Absolute path to a .bluebook file."),
  },
  async run(args) {
    const result = await runCli("parse", [args.bluebook_path]);
    return toMcpResponse(result);
  },
};
