# A refusal is `ok: false` with an error, and has no `supported` flag

**Status:** Accepted. Date: 2026-11-04. Owner decision on the survey's item 9 ("honest-refusal tools").

## Context

The survey asked for honest refusals: a structured answer such as `{ok: false, supported: false,
error: "..."}` in place of a crash, a missing file or a silent no-op.

The codebase already returns a structured refusal. The MCP tool calls answer `{ok: false, error:
"..."}` for a domain refusal, for a failed call and for an unknown tool
(`lib/hecks/adapters/driving/mcp/tool_calls.rb`). The only `NotImplementedError` in the driving
adapters is a developer-facing guard in `github_webhook.rb`, not an operation a client can call.

## Decision

1. A refusal is `{ok: false, error: "<message>"}`. Every driving surface that answers over a
   protocol uses this shape.
2. No `supported` field is added. A client does not need to tell "not available here" from
   "refused" today, so the extra field would be a second shape for the same case.
3. An operation a surface does not offer is refused with the same shape and a message that names
   the surface. It is not a crash and not a silent no-op.

## Consequences

- Survey item 9 is closed without new code.
- If a client later needs to tell an unavailable operation from a refused one, that is a new
  decision, recorded then.
