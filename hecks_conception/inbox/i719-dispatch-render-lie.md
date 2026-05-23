# i719 — "dispatch did not start" render lie

`dispatch_render` and `dispatch_digest` in `storehouse-mcp` label any dispatch whose
`events` array is empty as **"dispatch did not start"**. This is wrong for warm
dispatches : the warm path returns `events: []` (because the daemon doesn't include
them in the envelope — see i718), so every warm dispatch looks dead even when it
applied a command and mutated state.

## Root cause

The "did not start" heuristic conflates two distinct cases :

1. The command genuinely was not executed (e.g. a cold-path parse error, a timeout,
   a misrouted FQN).
2. The command executed successfully but the result envelope carries no events (warm
   path, or a command that emits nothing).

A warm path RESULT with no events is **not** a non-execution — it is a successful
dispatch with missing event metadata.

## Fix direction

Distinguish by presence of a `"result"` field (or a non-error `"ok"` flag) in the
response envelope :

- `ok: true, events: []` → "dispatch applied (no events)" — not "did not start".
- `ok: false` or missing `result` → "dispatch did not start" / error.

The label and the render text should reflect the actual outcome. Once i718 lands and
events flow in the envelope, `dispatch_render` can graduate to showing the event list.
