// read.mjs — storehouse__read → Tools.Read

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__read",
  title: "Tools.Read via Storehouse",
  description:
    "Read a file's contents through the Hecks Tools.Read dispatch. Emits FileRead. The full content rides through the event payload ; the response state carries path + captured output.",
  verb: "Tools.Read",
  inputSchema: {
    ...COMMON,
    file_path: z
      .string()
      .min(1)
      .describe("Absolute path preferred. Relative paths resolve against cwd."),
  },
  encode: (a) => ({
    id: a.id,
    file_path: a.file_path,
    description: a.description,
  }),
};
