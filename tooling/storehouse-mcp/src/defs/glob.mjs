// glob.mjs — storehouse__glob → Tools.Glob

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__glob",
  title: "Tools.Glob via Storehouse",
  description:
    "List files matching a glob pattern through the Hecks Tools.Glob dispatch. Emits GlobMatched.",
  verb: "Tools.Glob",
  inputSchema: {
    ...COMMON,
    glob_pattern: z
      .string()
      .min(1)
      .describe("Filesystem glob pattern (e.g. 'rust/src/**/*.rs')."),
    search_path: z
      .string()
      .optional()
      .describe("Directory to root the glob in. Defaults to cwd."),
  },
  encode: (a) => ({
    id: a.id,
    glob_pattern: a.glob_pattern,
    search_path: a.search_path,
    description: a.description,
  }),
};
