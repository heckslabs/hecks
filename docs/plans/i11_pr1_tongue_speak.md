# i11 PR 1 — Tongue.Speak wired to real inference

Source: inbox `i11` + plan by Agent a5f61f5d on 2026-04-22.

## What landed (PR 0, PR #259)

- `Spend` aggregate with `Call` + `Budget` sub-aggregates. Commands: `RecordCall`, `SetBudget`, `OverrideBudget`, `ClearOverride`.
- `CircuitBreaker` aggregate with lifecycle (closed/open/half_open) + `TripWhenThresholdCrossed` policy.
- Fixtures: hourly $1, daily $5, monthly $50. Breakers: claude_api + ollama_api closed.
- Both added to `PRIVATE_STORES`.

## Gaps found by the plan agent (must ship in PR 1)

1. **`claude_assist.bluebook` doesn't exist.** PR 1 creates a small `Config` aggregate: provider ∈ {claude, ollama, off}, daily_cap_usd, claude_model.
2. **`tongue.hecksagon` doesn't exist.** PR 1 creates it with `adapter :shell, name: :claude_speak`.
3. **`Spend.IsOverBudget(period)` query doesn't exist.** Add.
4. **`CircuitBreaker.IsOpen(kind)` query doesn't exist.** Add.

## ⚠ Open decision before implementing

**Chris uses Claude Max + CLI login, not API keys.** Meaning:

- **No `ANTHROPIC_API_KEY` env var** — the `claude` CLI inherits auth from his Max subscription.
- **No per-token USD billing** from his side — Max is flat-rate with usage limits.
- **Spend aggregate's USD caps don't map cleanly.** Daily/monthly $5/$50 caps are meaningless against a flat-rate subscription.

Before implementing, pick one:

1. **Drop USD entirely**; cap by **call count** (e.g. 100 calls/hour) and **token volume** (e.g. 1M tokens/day — observable via Claude's response envelope). Rename `Spend` → `Usage` or similar.
2. **Keep USD for accounting/telemetry only** — compute estimated cost from rate card, record it for visibility, but never block on it. Block instead on call/token limits.
3. **Hybrid**: record USD estimates, enforce on call count + token volume.

Recommended: **option 3** — USD visibility is useful if Chris ever switches to API billing or shares the tooling; call/token enforcement matches his actual reality. Requires minor rename of `Spend.Budget` semantics and field additions to `Call`.

Tag it in the first commit of PR 1.

## Key decisions

1. **Speech event shape**: keep `Spoken` minimal (downstream `RespondOnSpoken` depends on it — don't break). Add `SpeechFailed` / `SpeechTimedOut` / `SpeechSkipped` as siblings. Extra state (provider, latency_ms, cost_cents, tokens_in/out) on the Speech record, not on Spoken.
2. **Prompt scaffolder as its own aggregate**: `Tongue.BuildPrompt` on a new `Prompt` aggregate. Rejected "inside shell adapter" (wrong direction) and "hecksagon helper" (breaks declarative-structure pattern). Matches existing `Inference.Prompt` pattern.
3. **No retries**. Budget protection > latency optimization. Failure → `SpeechFailed` + circuit breaker tick.
4. **Ruby gets full Claude; Rust stays on ollama-only**. Minimum parity: both respect `provider`; Rust sees `claude` and emits `SpeechSkipped(reason: "provider_unsupported_in_runtime")`.
5. **Shell adapter args form**: `claude -p --output-format json --system-prompt-file {{path}} {{body}}`. List-of-strings. No stdin piping in v1.
6. **Env whitelist**: PR #251's `unsetenv_others: true` is strict. Claude CLI needs `HOME` (for auth cache) + `PATH`. Explicitly pass via adapter's `env:` attribute.
7. **Boot-time auth probe**: if `claude --version` fails + provider is "claude", auto-flip to "off" and warn. Don't silently fall back to ollama.

## Prompt scaffold structure (8k token budget)

1. **Persona** — `system_prompt.md` verbatim via `--system-prompt-file`. Never truncated.
2. **Mood/focus frame** — one line from `Tongue.Voice` + mood/topic snapshot. ~50 tokens. Never truncated.
3. **Conversation tail** — last N turns from `miette.Conversation.last_exchange`. Packed newest-first, reversed chronologically for display. Budget ~6500 tokens.
4. **Current input** — from attrs.

Truncation order: drop oldest turns → truncate input to last 4000 tokens → if persona alone exceeds, abort with `SpeechFailed(reason: "prompt_too_large")`.

## Commit sequence (8)

1. `claude_assist.bluebook` + `.hecksagon` + `.behaviors` — Config aggregate
2. `spend.bluebook` adds `IsOverBudget` query + spec
3. `circuit_breaker.bluebook` adds `IsOpen` query + spec
4. `tongue.bluebook` extensions — Speech attrs, failure events, Prompt aggregate
5. `tongue.hecksagon` — new file, claude_speak adapter + gates
6. Prompt scaffolder Ruby module (`lib/miette/tongue/prompt_builder.rb`)
7. Speech dispatcher wiring — orchestrates provider → budget → breaker → BuildPrompt → ShellDispatcher → parse → RecordCall → RecordSuccess → Spoken
8. `Tongue::ReplayCache` shim + integration tests

## Fuzzer hook (for i30)

`HECKS_LLM_REPLAY=/path/to/cassettes` env var. Record mode writes `{sha256(prompt_body)[:16]}.json`; replay mode reads same, skips shell-out, still emits same events.

## Risks

1. **Claude CLI auth** — addressed by boot probe
2. **Context poisoning via conversation.heki** — documented, deferred to PR 2+
3. **Cost overrun** — budget caps + override recorded_at as wall-clock UTC
4. **Breaker miscalibration** — defaults 5/60s/300s, acceptable
5. **Prompt via argv** — 32KB comfortable, switch to stdin if we push to 100k context

## Key files to create/modify

- NEW: `hecks_conception/aggregates/claude_assist.bluebook` + `.hecksagon` + `.behaviors`
- MODIFY: `hecks_conception/aggregates/spend.bluebook` (add query)
- MODIFY: `hecks_conception/aggregates/circuit_breaker.bluebook` (add query)
- MODIFY: `hecks_conception/aggregates/tongue.bluebook` (Speech extensions + Prompt aggregate)
- NEW: `hecks_conception/aggregates/tongue.hecksagon`
- NEW: `lib/miette/tongue/prompt_builder.rb`
- NEW: speech dispatcher (location TBD — probably `lib/hecks/runtime/speech_dispatcher.rb`)
- NEW: `Tongue::ReplayCache`
- NEW: spec coverage in `tongue.behaviors`

## What PR 1 does NOT do

- No Tongue.Hear yet (PR 2)
- No Capability.InvokeAgent yet (PR 3, needs i23 first)
- No Impulse → Capability dispatch chain (PR 5)
- No autonomous daemon boot (PR 6)
