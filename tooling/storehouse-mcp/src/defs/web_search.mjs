// web_search.mjs — storehouse__web_search → Tools.WebSearch

import { z } from "zod";
import { COMMON } from "./common.mjs";

export default {
  name: "storehouse__web_search",
  title: "Tools.WebSearch via Storehouse",
  description:
    "Search the web with a query through the Hecks Tools.WebSearch dispatch. Emits WebSearched.",
  verb: "Tools.WebSearch",
  inputSchema: {
    ...COMMON,
    query: z.string().min(1).describe("Search query string."),
  },
  encode: (a) => ({
    id: a.id,
    query: a.query,
    description: a.description,
  }),
};
