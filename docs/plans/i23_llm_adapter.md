# i23 — `adapter :llm` as first-class runtime capability

Source: inbox `i23` + plans by Agent a041108 (v1, 91 lines) + Agent a2297124 (refined 2026-04-22).

> **Status:** queued. Depends on nothing unshipped. Unblocks i11 PR 3+.

## Reality check

Chris uses **Claude Max + CLI login**, not API keys. The `:claude`
provider prefers CLI subprocess (`claude -p …`, subscription auth) and
only falls back to Anthropic API when `ANTHROPIC_API_KEY` is set.
Accounting model matches i11 PR 1: call/token caps, USD as telemetry only.

Existing `hecks_life/src/runtime/adapter_llm.rs` (56 LoC, Ollama-only,
hardcoded prompt) stays as parallel infra until Rust parity (Stage B).

## §1 — Current state

| Artifact | LoC | Status |
|---|---|---|
| `adapter_llm.rs` (Ollama-only) | 56 | Lives; Stage B replaces |
| `mint_musing.sh` (claude/API/CLI/ollama switch) | 173 | First retirement target |
| `spend.bluebook` + `circuit_breaker.bluebook` (PR #259) | 219 | No dispatcher consumes |
| `inference.bluebook` | 95 | Exists; no execution |
| `miette.world` (ollama config) | 10 | Hardcoded |

**Why centralization matters:**
- Provider switch is duplicated in mint_musing.sh. Next caller copies 40 LoC.
- `Spend.RecordCall` exists but nothing calls it — **no record** of Claude calls today.
- `CircuitBreaker` is orphaned. Outage = N timeouts, not 1-then-open.
- Streaming isn't modeled. Statusline can't show "🤔 thinking" mid-call.
- Prompt scaffolding is ad-hoc per caller (Ilya's "absorption" gap).

## §2 — Hecksagon `adapter :llm` shape

Direct mirror of PR #251's `adapter :shell`:

```ruby
adapter :llm, name: :speech do
  provider_ref "information/claude_assist.heki"   # runtime-switched
  fallback     :ollama, model: "llama3", url: "http://localhost:11434"

  prompt do
    scaffold :command_metadata                    # auto from command
    system   "You are Miette. Be concise."
    persona_file "system_prompt.md"
    max_tokens 400
    temperature 0.7
  end

  stream        true
  timeout       30
  output_format :text                             # :text | :json | :stream_json
  usage_ref     "aggregates/spend.bluebook"       # RecordCall target
  breaker_ref   :claude_api                       # CircuitBreaker kind
  on_response   :response
  on_tokens     :tokens_in, :tokens_out
  on_stream     :stream_chunk                     # optional per-chunk command
end
```

### Three distinctions from `:shell`

1. **Provider switch** — `:claude`/`:ollama`/`:openai`/`:test`/`:off` runtime-chosen.
2. **Streaming** — chunk-yielding iterator. Output: `:stream_json` (SSE) / `:json_lines`.
3. **Auto usage accounting** — every call → `Spend.RecordCall`; failures → `CircuitBreaker.RecordFailure`.

## §3 — Provider implementations

### `:claude` (Ruby)
- **CLI path (default)**: `claude -p --output-format stream-json …` via `Open3.popen3`, `unsetenv_others: true` + `HOME`+`PATH` pass-through. Parse stream-json; accumulate tokens from `message_stop`.
- **API path** (`ANTHROPIC_API_KEY` present): Net::HTTP to `api.anthropic.com/v1/messages`, SSE parse for stream.
- **Boot probe**: `claude --version`. On failure + provider=claude, mark degraded; dispatcher returns `LlmInvocationSkipped(reason: "provider_unavailable")`.

### `:ollama` (Ruby)
HTTP client against `config.url || "http://localhost:11434"`. Stream: `response.read_body { |chunk| … }`, parse json_lines.

### `:test` (Ruby) — **required for CI**
- `@fixtures`: prompt_sha256 → canned response
- Strict mode (CI, `HECKS_LLM_FIXTURE_STRICT=1`): unknown hash raises
- Capture/replay via `HECKS_LLM_CAPTURE` / `HECKS_LLM_REPLAY` (i30 fuzzer hook)

### `:openai` — deferred

## §4 — Dispatcher pipeline

```
LlmDispatcher.call(adapter, attrs)
  1. resolve provider (provider_ref | provider | fallback)
  2. resolve breaker kind (breaker_ref || "#{name}_api")
  3. CircuitBreaker.IsOpen? → LlmInvocationSkipped(reason: "breaker_open")
  4. Spend.IsOverBudget?    → LlmInvocationSkipped(reason: "budget_exceeded")
  5. PromptScaffolder.build(command, attrs, scaffold_directive, system, persona)
  6. provider.invoke(prompt, config)
     ├─ success: Spend.RecordCall + CircuitBreaker.RecordSuccess + LlmInvocationCompleted
     └─ failure: CircuitBreaker.RecordFailure + LlmInvocationFailed → raise
```

**Crash ordering**: provider success + RecordCall failure still emits
LlmInvocationCompleted + returns response. Missing-record better than
lost-response; reconcile daemon catches up.

**Override bypass**: `override_active == "yes"` + `override_until >= now`
skips IsOverBudget. Logs `LlmInvocationOverbudgetBypass`.

## §5 — Bluebook call-site ergonomics

**Implicit** (matches inference.bluebook):
```ruby
aggregate "Curator" do
  attribute :idea, String
  attribute :response, String       # :on_response target
  attribute :tokens_in, Integer
  attribute :tokens_out, Integer
  command "CurateMusing" do
    description "Generate a minted musing"
    attribute :idea, String
    emits "MusingCurated"
  end
end
```
Adapter resolves post-dispatch; if on_response empty + input non-empty, fires.

**Explicit**: `app.llm(:curate, idea: "…")`.

## §6 — PromptScaffolder

For `scaffold :command_metadata`:
```
SYSTEM:
You are dispatching the {Aggregate.Command} command.
Description: {command.description}
When to fire: {guards joined with "AND"}
On success, you will set: {then_set pairs}
State fields in scope: {reads}

USER:
{runtime attrs as labeled fields}
```

Deterministic (hash-stable for replay cache); PII-aware (strips
`pii`-tagged fields via `aggregate_capabilities`).

## §7 — Consumer audit (retirement targets)

| Caller | LoC | Replacement |
|---|---|---|
| `mint_musing.sh` | 173 | `Curator.CurateMusing` via `adapter :llm, name: :curate` |
| `adapter_llm.rs` | 56 | Stage B parallel Rust dispatcher |
| Tongue.Speak (i11 PR 1) | — | `adapter :llm, name: :speak` follow-up |
| Greeting / Daydream / REM / interpret_dream | shell | Opt-in `:llm` adapter |

One retirement per follow-up PR.

## §8 — Commit sequence (Stage A, Ruby-only)

1. `feat(hecksagon): Structure::LlmAdapter value object`
2. `feat(hecksagon): LlmAdapterBuilder DSL` (+ nested PromptBuilder)
3. `feat(hecksagon): wire adapter :llm into HecksagonBuilder`
4. `feat(runtime): LlmDispatcher + TestProvider`
5. `feat(runtime): ClaudeProvider + OllamaProvider`
6. `feat(runtime): Spend + CircuitBreaker integration`
7. `feat(runtime): PromptScaffolder + scaffold :command_metadata`
8. `feat(runtime): boot-time registration + Runtime#llm`
9. `docs: usage/llm_adapter.md + migration note`

Stage B (Rust parity): separate plan. Extends `hecksagon_ir.rs` +
`hecksagon_parser.rs` with `:llm`; parallel `llm_dispatcher.rs`;
replaces `adapter_llm.rs` resolve hook.

## §9 — LoC estimate

| Area | Prod | Specs |
|---|---|---|
| Ruby IR + DSL | ~280 | ~240 |
| Runtime (dispatcher + providers + scaffolder) | ~1,100 | ~540 |
| Boot wiring + Runtime#llm | ~60 | ~60 |
| Errors + replay hooks | ~80 | ~30 |
| Docs | — | ~210 |

**Total Stage A: ~2,600 LoC.** Comparable to PR #251 (`adapter :shell`, ~2,400).

## §10 — Risks

1. **Streaming + Spend on partial crash** — under-counts failed-stream tokens; accepted.
2. **Claude CLI env whitelist** — must pass `HOME`+`PATH`. Controlled relaxation in `LlmAdapter#env` defaults; `:shell`-level `unsetenv_others: true` stays strict.
3. **Prompt scaffolding leakage** — opt-in metadata whitelist; `pii`-tagged fields stripped.
4. **Budget races** — serialize via command bus.
5. **Fixture drift** — `HECKS_LLM_FIXTURE_STRICT` errors on miss; regenerate via `HECKS_LLM_CAPTURE`.
6. **Subscription auth expiry** — dispatcher emits `LlmInvocationFailed(reason: "auth_invalid")`, opens breaker. User re-runs `claude login`.
7. **Infinite prompt loops** — scaffolder strips `on_response` from state before building prompt.
8. **Rate limits** — breaker opens on 429. Exponential backoff on half-open probe is v2.

## §11 — Relationship to i11

- **i11 PR 1** (Tongue.Speak via `adapter :shell`) ships FIRST — simpler, no new adapter kind.
- **i23** ships second — lands `adapter :llm` end-to-end. PR 1's `claude_speak` shell adapter becomes a candidate for migration to `:llm` (~5-line follow-up).
- **i11 PR 3** (Capability.InvokeAgent) depends on i23.

## §12 — Out of scope (Stage A)

- Rust runtime parity (Stage B)
- `:openai` (deferred to first use case)
- Multi-turn conversation state (caller's job)
- Tool-use / function-calling (i11 PR 3)
- Vision/multimodal
- Prompt caching (Anthropic API)

## Critical files

- `lib/hecksagon/dsl/hecksagon_builder.rb` — `adapter(kind, …)` dispatch
- `lib/hecksagon/dsl/shell_adapter_builder.rb` — reference pattern
- `lib/hecks/runtime/shell_dispatcher.rb` — reference dispatcher
- `lib/hecks/runtime.rb` — `#register_shell_adapter` / `#shell` mirror
- `lib/hecks/runtime/boot.rb` — `wire_shell_adapters` mirror
- `hecks_conception/aggregates/spend.bluebook` — accounting
- `hecks_conception/aggregates/circuit_breaker.bluebook` — gating
- `hecks_conception/mint_musing.sh` — first retirement target
- `hecks_life/src/runtime/adapter_llm.rs` — parallel Rust (until Stage B)
