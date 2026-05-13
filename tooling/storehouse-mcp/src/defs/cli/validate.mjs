// validate.mjs — storehouse__validate → `storehouse validate <bluebook-path>`
//
// Runs the runtime's bluebook validator against a single bluebook file.
// Returns the stdout (e.g. "VALID — World (1 aggregates)") and exit code.

import { z } from "zod";
import { runCli, toMcpResponse } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__validate",
  title: "Validate a Bluebook",
  description:
    "Run `storehouse validate <bluebook>` — checks the bluebook parses cleanly and passes DDD-consistency rules. Use this before macrophage_check or behaviors.",
  inputSchema: {
    bluebook_path: z
      .string()
      .min(1)
      .describe("Absolute path to a .bluebook file."),
  },
  async run(args) {
    const result = await runCli("validate", [args.bluebook_path]);
    return toMcpResponse(result);
  },
};
