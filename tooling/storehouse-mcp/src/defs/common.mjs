// common.mjs
//
// Schema fields every storehouse__* tool inherits — `id` (stable
// invocation id) and `description` (one-line caption). Extracted so
// the per-tool defs stay tight and re-use the same describe() text.

import { z } from "zod";

export const COMMON = {
  id: z
    .string()
    .min(1)
    .describe(
      "Stable invocation id — the bluebook persists by id so downstream listeners can join results back. Pass a ULID or other unique string.",
    ),
  description: z
    .string()
    .optional()
    .describe("One-line caption in active voice. Under 80 chars by convention."),
};
