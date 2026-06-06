// describe_aggregate.mjs — storehouse__describe_aggregate
//
// Emits the canonical-IR JSON for ONE aggregate inside a bluebook — the
// structured shape produced by dump::dump_aggregate. Use to look up an
// aggregate's commands, queries, attributes, references, and value objects
// before constructing a dispatch verb. For the full domain catalog, use
// storehouse__catalog.
//
// There is no `storehouse describe` CLI subcommand ; this tool shells
// `storehouse dump <bluebook>` (the whole-domain canonical IR) and filters
// to the named aggregate in-process. A miss returns isError with the list
// of available aggregate names so the caller can correct the spelling.

import { z } from "zod";
import { runCli } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__describe_aggregate",
  title: "Describe One Aggregate",
  description:
    "Emit the canonical-IR JSON for one aggregate inside a bluebook. Shows commands, queries, attributes, references, value_objects, lifecycle states, and entities. Shells `storehouse dump <bluebook>` and filters to the named aggregate. Use as a focused discovery probe before storehouse__dispatch ; for the whole domain use storehouse__catalog.",
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
    const result = await runCli("dump", [args.bluebook_path]);
    if (!result.ok) {
      return {
        content: [{ type: "text", text: result.stderr || result.stdout || `exit=${result.exit_code}` }],
        isError: true,
      };
    }
    let domain;
    try {
      domain = JSON.parse(result.stdout.trim());
    } catch (err) {
      return {
        content: [{ type: "text", text: `could not parse dump output as JSON: ${err.message}` }],
        isError: true,
      };
    }
    const aggregates = Array.isArray(domain.aggregates) ? domain.aggregates : [];
    const match = aggregates.find((a) => a.name === args.aggregate_name);
    if (!match) {
      const available = aggregates.map((a) => a.name).join(", ");
      return {
        content: [{ type: "text", text: `aggregate "${args.aggregate_name}" not found. available: [${available}]` }],
        isError: true,
      };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(match, null, 2) }],
      isError: false,
    };
  },
};
