// edit.mjs — storehouse__edit → Tools.Edit

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__edit",
  title: "Tools.Edit via Storehouse",
  description:
    "Apply a substring substitution to a file through the Hecks Tools.Edit dispatch. Emits EditApplied.",
  verb: "Tools.Edit",
  inputSchema: {
    ...COMMON,
    file_path: z.string().min(1).describe("Path of the file to edit."),
    old_string: z.string().describe("Substring to replace."),
    new_string: z.string().describe("Substring to substitute in."),
    replace_all: z
      .boolean()
      .optional()
      .describe(
        "When true, replace every occurrence. When false (default), require exactly one match.",
      ),
  },
  encode: (a) => ({
    id: a.id,
    file_path: a.file_path,
    old_string: a.old_string,
    new_string: a.new_string,
    replace_all: a.replace_all,
    description: a.description,
  }),
};
