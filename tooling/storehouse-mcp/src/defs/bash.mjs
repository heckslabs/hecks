// bash.mjs — storehouse__bash → Tools.Bash

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__bash",
  title: "Tools.Bash via Storehouse",
  description:
    "Run a shell command through the Hecks Tools.Bash dispatch. Emits BashRan ; the runtime substrate executes the shell and returns stdout + exit code in the response state.",
  verb: "Tools.Bash",
  inputSchema: {
    ...COMMON,
    shell_command: z
      .string()
      .min(1)
      .describe("The shell command line to execute, verbatim."),
  },
  encode: (a) => ({
    id: a.id,
    shell_command: a.shell_command,
    description: a.description,
  }),
};
