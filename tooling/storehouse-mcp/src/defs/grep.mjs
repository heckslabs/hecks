// grep.mjs — storehouse__grep → Tools.Grep

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__grep",
  title: "Tools.Grep via Storehouse",
  description:
    "Search files for a regex pattern through the Hecks Tools.Grep dispatch. Emits GrepRan.",
  verb: "Tools.Grep",
  inputSchema: {
    ...COMMON,
    pattern: z.string().min(1).describe("Regex pattern (PCRE2 / ripgrep syntax)."),
    search_path: z
      .string()
      .optional()
      .describe("Directory or file to search. Defaults to cwd when omitted."),
  },
  encode: (a) => ({
    id: a.id,
    pattern: a.pattern,
    search_path: a.search_path,
    description: a.description,
  }),
};
