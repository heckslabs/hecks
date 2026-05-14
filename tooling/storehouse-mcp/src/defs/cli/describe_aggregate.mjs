// describe_aggregate.mjs — storehouse__describe_aggregate
//                       → `storehouse describe <bluebook> <aggregate>`
//
// Emits the canonical-IR JSON for one aggregate inside a bluebook —
// the structured shape produced by dump::dump_aggregate. Use to look
// up an aggregate's commands, queries, attributes, requires guards,
// and value objects before constructing a dispatch verb. For the full
// domain catalog, use storehouse__catalog.

import { z } from "zod";
import { runCli, toMcpResponse, toMcpResponsePretty } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__describe_aggregate",
  title: "Describe One Aggregate",
  description:
    "Emit the canonical-IR JSON for one aggregate inside a bluebook. Shows commands, queries, attributes, references, value_objects, lifecycle states, and entities. Wraps `storehouse describe <bluebook> <aggregate>`. Use as a focused discovery probe before storehouse__dispatch.",
  inputSchema: {
    bluebook_path: z
      .string()
      .min(1)
      .describe("Absolute path to a .bluebook file."),
    aggregate_name: z
      .string()
      .min(1)
      .describe(
        "Exact aggregate name (case-sensitive). Get the available list from storehouse__list_aggregates.",
      ),
  },
  async run(args) {
    const result = await runCli("describe", [args.bluebook_path, args.aggregate_name]);
    return toMcpResponsePretty(result);
  },
};
