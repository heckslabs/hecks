// macrophage_check.mjs — storehouse__macrophage_check → `storehouse macrophage`
//
// The macrophage is a PostToolUse-style enforcer that reads a tool-input
// payload from stdin and complains if the touched file isn't a bluebook.
// For an on-demand CLI check we synthesize the stdin payload with the
// bluebook_path so callers can spot-check the macrophage's verdict
// without running it as a hook.

import { z } from "zod";
import { runCli, toMcpResponse } from "../../cli_dispatch.mjs";

export default {
  name: "storehouse__macrophage_check",
  title: "Run Macrophage on a Bluebook",
  description:
    "Run the macrophage discipline check against a file path. Wraps `storehouse macrophage` with a synthesized tool-input payload. Returns the macrophage's state JSON ; complaints surface under state.last_complaint.",
  inputSchema: {
    bluebook_path: z
      .string()
      .min(1)
      .describe(
        "Absolute path to the file the macrophage should evaluate (typically a .bluebook).",
      ),
  },
  async run(args) {
    const payload = JSON.stringify({
      tool_input: { file_path: args.bluebook_path },
    });
    const result = await runCli("macrophage", [], { stdin: payload });
    return toMcpResponse(result);
  },
};
