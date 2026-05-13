// state.mjs — storehouse__state
//          → `storehouse state <root> <aggregate-name> <id>`
//
// Direct read of one aggregate instance's current runtime state by id.
// Boots the runtime against the aggregates root, calls Runtime::find,
// and emits { ok, aggregate, id, state } as JSON. A missing record
// returns ok:false with state:null (not an error — "no such record"
// is a normal answer to a state query).

import { z } from "zod";
import { runCli, toMcpResponse } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__state",
  title: "Read Aggregate State by ID",
  description:
    "Read the current state of one aggregate instance by its id. Boots the runtime against the aggregates root and returns { ok, aggregate, id, state } as JSON. ok=false with state=null when no record matches (not an error). Wraps `storehouse state <root> <aggregate> <id>`.",
  inputSchema: {
    aggregates_dir: z
      .string()
      .min(1)
      .describe(
        "Absolute path to the aggregates root (where the .heki stores live).",
      ),
    aggregate_name: z
      .string()
      .min(1)
      .describe(
        "Aggregate name (e.g. 'ShellTool', 'Session'). Case-sensitive.",
      ),
    id: z
      .string()
      .min(1)
      .describe("The aggregate instance's id."),
  },
  async run(args) {
    const result = await runCli("state", [
      args.aggregates_dir,
      args.aggregate_name,
      args.id,
    ]);
    return toMcpResponse(result);
  },
};
