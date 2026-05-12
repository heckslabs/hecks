// record_result.mjs — storehouse__record_result → Tools.RecordResult
//
// The bluebook command takes `tool` (not `tool_kind`) and `ok` (not
// `ok_status`) — see tools.bluebook lines 411-414. The MCP tool name
// uses the response-state field names (which is what the runtime
// surfaces back) ; the encode step re-maps to the command attrs.

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__record_result",
  title: "Tools.RecordResult via Storehouse",
  description:
    "Record the outcome of a previous Tools.* dispatch back onto the aggregate, joined by invocation id. Emits ResultRecorded. Normally fired by the kernel hook, but exposed here so callers can write back results themselves.",
  verb: "Tools.RecordResult",
  inputSchema: {
    ...COMMON,
    tool_kind: z
      .string()
      .min(1)
      .describe(
        "Which tool produced the result : one of bash, edit, read, write, grep, glob, web_fetch, web_search.",
      ),
    output: z.string().describe("Captured stdout / tool output."),
    exit_code: z.number().int().describe("Process exit code (0 = success)."),
    ok_status: z.boolean().describe("Coarse-grained success flag."),
  },
  encode: (a) => ({
    id: a.id,
    tool: a.tool_kind,
    output: a.output,
    exit_code: a.exit_code,
    ok: a.ok_status,
  }),
};
