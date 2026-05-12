// web_fetch.mjs — storehouse__web_fetch → Tools.WebFetch

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__web_fetch",
  title: "Tools.WebFetch via Storehouse",
  description:
    "Fetch a URL and process its content through the Hecks Tools.WebFetch dispatch. Emits WebFetched.",
  verb: "Tools.WebFetch",
  inputSchema: {
    ...COMMON,
    url: z.string().url().describe("URL to fetch, including scheme."),
    prompt: z
      .string()
      .optional()
      .describe("Instruction for processing the fetched content."),
  },
  encode: (a) => ({
    id: a.id,
    url: a.url,
    prompt: a.prompt,
    description: a.description,
  }),
};
