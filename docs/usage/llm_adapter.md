# LLM Adapter (`adapter :llm`)

An LLM adapter is a named, prompt-template-based binding to an LLM
backend (Claude, Ollama, fixture, ...) declared in a `.hecksagon`. It
mirrors `adapter :shell` shape — one named adapter per binding, many
allowed per hecksagon — but its dispatcher speaks to language-model
providers instead of subprocesses.

> **Status — Phase 1 (shipped):** the DSL keyword + value object
> (`Hecksagon::Structure::LlmAdapter`), the `LlmAdapterBuilder`, the
> Rust `hecksagon_parser` mirror, and the parity-fixture round-trip
> (`examples/llm_adapter/llm_demo.hecksagon` →
> `parity/canonical_ir.rb :: dump_llm_adapter`). At this phase
> declarations parse, register, and survive the Ruby↔Rust canonical
> JSON diff. The runtime dispatcher (Phase 2) lands separately ; until
> Phase 2 merges, declared adapters are inert IR.

## Three distinctions from `adapter :shell`

`:llm` is structurally a sibling of `:shell`, not a copy. The runtime
contract differs in three ways :

1. **Provider switch.** A shell adapter binds one binary. An LLM adapter
   binds an *abstract* call ; the concrete provider (`:claude`,
   `:ollama`, `:test`, `:fixture`, `:off`) is selected at boot from the
   adapter's `backend` field plus environment.
2. **Streaming-aware.** Shell dispatch is request/response — `Open3`
   captures stdout. LLM providers may yield chunks (`stream-json`, SSE)
   ; the dispatcher accumulates tokens but exposes a per-chunk hook.
3. **Auto usage accounting.** Every call records to
   `Spend.RecordCall` and respects `CircuitBreaker.IsOpen?`. Shell has
   no equivalent — its `Result` is opaque to spend.

## Phase 1 — what you can write today

The shipped surface is :

```ruby
Hecks.hecksagon "Dream" do
  adapter :memory                          # persistence, optional

  adapter :llm, name: :dream_image do      # llm — named, many allowed
    prompt_template "You are Miette dreaming. Seed: {{seed_image}}"
    model           "claude-sonnet-4"
    max_tokens      200
    response_into   "Dream.ProduceImage", attr: :text_fr
    backend         :claude
  end

  # One-liner form — apply_options shortcut :
  adapter :llm, name: :quick,
                prompt_template: "Hi {{name}}",
                model: "claude-sonnet-4",
                max_tokens: 50,
                backend: :claude
end
```

Phase 1 fields (matching `Hecksagon::Structure::LlmAdapter`) :

| Field | Type | Required | Notes |
|---|---|---|---|
| `name:` | Symbol | yes (when not falling back — see below) | Unique within the hecksagon. Look up via `hex.llm_adapter(:name)`. |
| `prompt_template` | String | no (defaults to `""`) | May contain any number of `{{token}}` placeholders. |
| `model` | String | no | Provider-specific identifier (e.g. `"claude-sonnet-4"`, `"llama3"`). |
| `max_tokens` | Integer | no | Coerced via `Integer(...)`. |
| `response_into` | dotted target + `attr:` | no | First positional is `"Aggregate.Command"` ; `attr:` keyword names the attribute on that command which receives the LLM's text. |
| `backend` | Symbol | no | `:claude`, `:ollama`, `:fixture`, `:test`, `:off` (and `:openai` reserved — see §out-of-scope). |

You can read the placeholders the runtime will need to fill :

```ruby
hex     = Dream.hecksagon
adapter = hex.llm_adapter(:dream_image)
adapter.placeholders  # => [:seed_image]
adapter.to_h          # => { name: :dream_image, prompt_template: "...", ... }
```

The minimal end-to-end parity fixture lives at
[`examples/llm_adapter/llm_demo.hecksagon`](../../examples/llm_adapter/llm_demo.hecksagon)
— it is the canonical Phase 1 example, exercised by
`parity/hecksagon_parity_test.rb` to prove Ruby↔Rust IR equivalence.

## Provider switching

Phase 1 lets you *declare* the backend ; Phase 2 binds it to a real
client. The provider matrix the Phase 2 plan locks in
([§3 of the plan](../plans/i23_llm_adapter.md#3--provider-implementations))
is :

| Backend symbol | Default path | Fallback / notes |
|---|---|---|
| `:claude` | **CLI subprocess** — `claude -p --output-format stream-json` via `Open3.popen3`, subscription auth (Claude Max). | If `ANTHROPIC_API_KEY` is set in env, dispatcher switches to `Net::HTTP` against `api.anthropic.com/v1/messages` (SSE for streaming). |
| `:ollama` | `Net::HTTP` against `config.url` or `http://localhost:11434`. | Streams via `response.read_body { ... }` parsing `json_lines`. |
| `:test` | In-process map of `prompt_sha256 → canned response`. | CI-required ; deterministic. |
| `:fixture` | Disk-backed canned responses keyed by prompt hash. | For replay/golden-master flows. |
| `:off` | Returns `LlmInvocationSkipped(reason: "provider_off")` immediately. | For env-disabled / kill-switch use. |

> **Note (Phase 2 step 5 — PR #TBD):** the provider implementations
> themselves land alongside the dispatcher in step 5. The `backend:`
> field in your hecksagon is wired today ; the actual `:claude` /
> `:ollama` HTTP and CLI paths arrive when step 5's PR merges. Until
> then, declarations type-check and round-trip through parity but do
> not invoke a model.

### `:claude` — CLI-over-API by design

Chris uses Claude Max with CLI login — no API key, the subscription
covers usage. The dispatcher therefore prefers the CLI path :

```bash
# Primary path — the CLI subprocess. No API key needed.
$ which claude && claude --version
/usr/local/bin/claude
1.x.y

# API path — only triggered when you explicitly opt in :
$ export ANTHROPIC_API_KEY=sk-ant-...
$ ruby -Ilib -e 'require "hecks"; Hecks.boot(__dir__).llm(:dream_image, seed_image: "fox")'
# now the dispatcher uses Net::HTTP instead of the claude CLI
```

The boot probe runs `claude --version` once at startup. If it fails *and*
`backend: :claude` is declared *and* `ANTHROPIC_API_KEY` is unset, the
dispatcher returns `LlmInvocationSkipped(reason: "provider_unavailable")`
rather than crashing — a missing CLI is a graceful-degradation case, not
an invariant violation.

## Backward-compat — bare `adapter :llm`

Before this DSL keyword landed, several production hecksagons
(`wake_review`, `musing_mint`, `dream_review`, `rem_dream`) already
wrote :

```ruby
adapter :llm, backend: :claude
```

— without a `name:`. To avoid breaking them, the Phase 1 dispatcher
**falls back to the io-adapter bucket when `name:` is omitted** :

```ruby
# bare form — registers as io_adapter(kind: :llm), NOT as a named
# llm_adapter. matches Rust's parser_helpers behaviour.
builder.adapter :llm, backend: :claude
hex = builder.build

hex.llm_adapters                                  # => []
hex.io_adapters.find { |a| a.kind == :llm }       # => present, options: { backend: :claude }
```

This is the contract pinned by the Phase 1 spec
(`spec/hecksagon/dsl/hecksagon_builder_llm_adapter_spec.rb`,
"falls back to the io_adapter bucket when name: is omitted") and
mirrored in `rust/src/hecksagon_parser.rs`.

**Guidance for new code :** always provide `name:`. The bare form is
preserved for parity with shipped hecksagons only ; new code uses the
named form so the runtime dispatcher in Phase 2 can resolve the
adapter by name (`runtime.llm(:curate, ...)`).

## Test seam — `:fixture` / `:test`

The `:test` and `:fixture` backends exist so byte-exact, deterministic
test runs are first-class — no network, no subscription, no CI flakes.

Phase 2 will surface three environment variables governing replay
behavior :

| Env var | Effect |
|---|---|
| `HECKS_LLM_FIXTURE_STRICT=1` | In CI : an unknown prompt hash raises rather than falling back to live calls. Default in `RACK_ENV=test`. |
| `HECKS_LLM_CAPTURE=<dir>` | Records every (prompt, response) pair to `<dir>` as fixture material. |
| `HECKS_LLM_REPLAY=<dir>` | Reads recorded pairs from `<dir>` ; on cache miss, the strict bit decides whether to raise or fall through. |

A test using the fixture seam is shape-equivalent to a live one — the
hecksagon is unchanged ; only the boot configuration picks the
provider :

```ruby
RSpec.describe "Curator" do
  before do
    @app = Hecks.boot(__dir__)              # hecksagon picks provider via env
    # provider :test is selected when HECKS_LLM_PROVIDER=test or
    # the hecksagon's backend resolves to :test at boot time.
  end

  it "curates a musing" do
    result = @app.llm(:curate, idea: "river of glass")
    expect(result.text).to start_with("A musing about")
  end
end
```

> **Note (Phase 2 step 4 — PR #TBD):** `Runtime#llm`, the dispatcher,
> the test provider, and the env-var contract above all land in
> Phase 2 step 4. Phase 1 ships only the IR — the env vars are
> documented here so the test seam is one place when step 4 merges.
> The capture/replay *file format* itself (Anthropic SSE vs Ollama
> json-lines normalization) is a follow-up beyond Phase 2 ; only the
> seam is contractual today.

## Spend + CircuitBreaker integration

Every Phase 2 dispatch participates in the spend / breaker pipeline
([§4 of the plan](../plans/i23_llm_adapter.md#4--dispatcher-pipeline)) :

```text
LlmDispatcher.call(adapter, attrs)
  1. resolve provider              (backend + env)
  2. resolve breaker kind          (breaker_ref || "#{name}_api")
  3. CircuitBreaker.IsOpen?        → LlmInvocationSkipped(reason: "breaker_open")
  4. Spend.IsOverBudget?           → LlmInvocationSkipped(reason: "budget_exceeded")
  5. PromptScaffolder.build(...)   (system + persona + scaffolded user prompt)
  6. provider.invoke(prompt, cfg)
     ├─ success → Spend.RecordCall + CircuitBreaker.RecordSuccess + LlmInvocationCompleted
     └─ failure → CircuitBreaker.RecordFailure + LlmInvocationFailed → raise
```

Two domain aggregates carry the contract :

- [`hecks_conception/aggregates/world/spend/call.bluebook`](../../hecks_conception/aggregates/world/spend/call.bluebook)
  +
  [`budget.bluebook`](../../hecks_conception/aggregates/world/spend/budget.bluebook)
  — `Spend.RecordCall` writes per-invocation token + cost rows ;
  `Spend.IsOverBudget?` queries the rolling budget. (Note : the plan
  refers to a flat `aggregates/spend.bluebook` ; the actual on-disk
  layout splits it into `spend/call.bluebook` and `spend/budget.bluebook`
  — both are the canonical source.)
- `aggregates/body/organs/circuit_breaker.bluebook` — the breaker
  aggregate gates calls and absorbs failures. (Currently lives only
  as a fixture in `hecks_conception/aggregates/fixtures/circuit_breaker.fixtures`
  ; Phase 2 step 6 promotes it to a full bluebook.)

Crash ordering is asymmetric on purpose : provider success + RecordCall
failure still emits `LlmInvocationCompleted` and returns the response.
Missing-record is a recoverable reconciliation problem ; lost-response
is a user-visible failure. The reconcile daemon catches up later.

> **Note (Phase 2 step 6 — PR #TBD):** the dispatcher's spend +
> breaker wiring lands in step 6, alongside the breaker bluebook
> promotion. Until step 6 merges, declared `:llm` adapters do **not**
> auto-record to spend.

## Migration from `mint_musing.sh`

The first retirement target is the 173-LOC `mint_musing.sh`
(plan §7). Today its provider switch is duplicated inline ; after
migration, the same logic collapses into a `Curator.CurateMusing`
command bound to a named LLM adapter.

**Before** — `mint_musing.sh` (sketch) :

```bash
#!/usr/bin/env bash
# 173 LoC : provider switch (claude CLI / API / ollama),
# prompt assembly, subprocess plumbing, error parsing,
# manual spend logging — all inline.
case "$LLM_PROVIDER" in
  claude_cli) claude -p "$(build_prompt)" ... ;;
  claude_api) curl https://api.anthropic.com/... ;;
  ollama)     curl http://localhost:11434/... ;;
esac
# ... 150 more lines of error handling, spend math,
# breaker bookkeeping, response parsing.
```

**After** — `mint_musing` becomes domain shape :

```ruby
# aggregates/curator.bluebook (sketch — still a follow-up PR)
aggregate "Curator" do
  attribute :idea,        String
  attribute :response,    String     # :on_response target
  attribute :tokens_in,   Integer
  attribute :tokens_out,  Integer

  command "CurateMusing" do
    description "Generate a minted musing"
    attribute :idea, String
    emits "MusingCurated"
  end
end
```

```ruby
# hecksagon for Curator
Hecks.hecksagon "Curator" do
  adapter :memory

  adapter :llm, name: :curate do
    prompt_template "Mint a musing about: {{idea}}"
    model           "claude-sonnet-4"
    max_tokens      400
    backend         :claude
    response_into   "Curator.CurateMusing", attr: :response
  end
end
```

```ruby
# call site — replaces 173 lines of bash
app.llm(:curate, idea: "river of glass")
# spend recording, breaker check, provider selection, streaming —
# all handled by the dispatcher.
```

Everything `mint_musing.sh` did imperatively now lives declaratively in
the bluebook + hecksagon, and centralisation gives every other caller
the same provider switch + spend + breaker for free.

> **Note :** the actual `mint_musing.sh` retirement is a follow-up PR
> after Phase 2 lands. The shape above is the destination, not the
> current state.

## Phase boundaries

| Phase | Status | Scope |
|---|---|---|
| **Phase 1** | shipped (`b4257c21`) | DSL keyword + IR value object + Rust parser + canonical-IR parity fixture. Declarations parse and round-trip. |
| **Phase 2** | in flight (steps 4–9, parallel) | Runtime dispatcher + `:claude`/`:ollama`/`:test` providers + `Spend` / `CircuitBreaker` integration + `PromptScaffolder` + boot wiring (`Runtime#llm`). |
| **Stage B** (deferred) | not yet planned in detail | Rust runtime parity — `storehouse` dispatcher mirroring the Ruby pipeline. The existing `storehouse/src/runtime/adapter_llm.rs` (Ollama-only, 56 LoC) lives in parallel until Stage B replaces it. |

## Out of scope (per i23 §12)

The following are deliberately deferred — they are *not* part of either
Phase 1 or Phase 2, and declaring `backend: :openai` or expecting
multi-turn behavior today will surface as missing-feature errors :

- **`:openai` provider** — deferred to first concrete use case.
- **Multi-turn conversation state** — caller's responsibility ; the
  dispatcher invokes single-shot completions only.
- **Tool-use / function-calling** — depends on i11 PR 3 (capability
  invocation infrastructure).
- **Vision / multimodal inputs** — text-only Phase 2.
- **Prompt caching (Anthropic API ephemeral cache)** — not modeled in
  the Phase 2 dispatcher contract.

## Related

- [`docs/plans/i23_llm_adapter.md`](../plans/i23_llm_adapter.md) —
  the design plan, including dispatcher pipeline (§4) and provider
  matrix (§3).
- [`docs/usage/shell_adapter.md`](shell_adapter.md) — the precedent
  this adapter mirrors structurally.
- [`examples/llm_adapter/llm_demo.hecksagon`](../../examples/llm_adapter/llm_demo.hecksagon)
  — the runnable Phase 1 parity fixture.
- [`docs/usage/antibody.md`](antibody.md) — why first-class native
  adapters close the antibody gap for ad-hoc scripts.
