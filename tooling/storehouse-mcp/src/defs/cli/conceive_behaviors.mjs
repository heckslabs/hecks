// conceive_behaviors.mjs — storehouse__conceive_behaviors
//                       → `storehouse conceive <bluebook> behaviors`
//
// Generates a behaviors companion file for a bluebook. The shape of the
// conceive subcommand has shifted a few times ; for the MVP we pass the
// bluebook path positionally and let the CLI surface its own error if
// the arg shape ever drifts. Callers can read stderr from
// structuredContent.stderr in that case.

import { z } from "zod";
import { runCli, toMcpResponse } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__conceive_behaviors",
  title: "Generate a Behaviors Companion",
  description:
    "Generate a behaviors companion (sample-coverage tests) for a bluebook. Wraps `storehouse conceive <bluebook>` in behaviors mode. Returns the conceive output.",
  inputSchema: {
    bluebook_path: z
      .string()
      .min(1)
      .describe("Absolute path to the source bluebook."),
  },
  async run(args) {
    // The conceive CLI accepts the bluebook as a positional argument and
    // emits the companion alongside it (or to stdout in dry-run modes).
    const result = await runCli("conceive", [args.bluebook_path]);
    return toMcpResponse(result);
  },
};
