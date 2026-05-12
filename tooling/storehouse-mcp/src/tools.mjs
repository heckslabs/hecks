// tools.mjs
//
// Tool registry index + runner. Each storehouse__* tool's schema and
// encode-fn lives in its own file under ./defs/ to keep file sizes
// small and let each tool's contract be read in isolation. This file
// just collects them and provides the runTool helper the server uses.

import { dispatch } from "./dispatch.mjs";

import bash from "./defs/bash.mjs";
import read from "./defs/read.mjs";
import edit from "./defs/edit.mjs";
import update from "./defs/update.mjs";
import grep from "./defs/grep.mjs";
import glob from "./defs/glob.mjs";
import webFetch from "./defs/web_fetch.mjs";
import webSearch from "./defs/web_search.mjs";
import recordResult from "./defs/record_result.mjs";

export const TOOLS = [
  bash,
  read,
  edit,
  update,
  grep,
  glob,
  webFetch,
  webSearch,
  recordResult,
];

// Run a tool by name with caller-supplied args. Returns the MCP-shaped
// response : a text content block with pretty-printed JSON, plus
// structuredContent for callers that want to consume it programmatically,
// plus isError reflecting the dispatch's ok flag.
export async function runTool(name, args) {
  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) throw new Error(`unknown tool: ${name}`);
  const attrs = tool.encode(args);
  const result = await dispatch(tool.verb, attrs);
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(result, null, 2),
      },
    ],
    structuredContent: result,
    isError: result.ok === false,
  };
}
