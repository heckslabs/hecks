// update.mjs — storehouse__update → Tools.Update

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__update",
  title: "Tools.Update via Storehouse",
  description:
    "Write content to a file through the Hecks Tools.Update dispatch (same semantic as Claude's native Write tool, renamed for state-changing dispatch emphasis). Emits FileUpdated.",
  verb: "Tools.Update",
  inputSchema: {
    ...COMMON,
    file_path: z.string().min(1).describe("Path of the file to write."),
    content: z.string().describe("Full content to write."),
  },
  encode: (a) => ({
    id: a.id,
    file_path: a.file_path,
    content: a.content,
    description: a.description,
  }),
};
