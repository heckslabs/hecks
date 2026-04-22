# i23 — `adapter :llm` as first-class runtime capability

Source: inbox `i23` + plan by Agent a041108 on 2026-04-22.

## ⚠ Reality check before implementing

**Chris uses Claude Max + CLI login, not API keys.** See the open decision at the top of `i11_pr1_tongue_speak.md`. The accounting model for `adapter :llm` should match: call/token-based usage caps, USD as telemetry only.

## What the adapter does

Direct mirror of PR #251's `adapter :shell` — named, many-per-hecksagon, block-or-options form:

```ruby
Hecks.hecksagon "..." do
  adapter :llm, name: :speech do
    provider_ref "information/claude_assist.heki"
    fallback      :ollama, model: "llama3", url: "http://localhost:11434"
    prompt do
      scaffold :command_metadata
      system   "You are Miette. Be concise."
      max_tokens 400
    end
    stream        true
    timeout       30
    usage_ref     "aggregates/spend.bluebook"    # record via Spend.RecordCall
    on_response   :response
    on_tokens     :tokens_in, :tokens_out
  end
end
```

## Three distinctions from `:shell`

1. **Provider switch** — claude/ollama/off chosen per-call from `claude_assist.heki` (not fixed binary)
2. **Streaming** — chunk-yielding iterator, not `capture3`
3. **Auto usage accounting** — every invocation triggers `Spend.RecordCall`

## Key decisions

- **`scaffold :command_metadata`** auto-builds the prompt from the triggering command's `description`, `guards`, `then_set` mutations, and state fields it reads. This is the "absorption" Ilya asked for — replaces the hardcoded `"You are Miette..."` in `adapter_llm.rs`.
- **Provider abstraction**: `ClaudeProvider` + `OllamaProvider` behind a `LlmProvider` trait. Shared `StreamingResult` yields chunks.
- **Security**: Claude CLI needs `HOME` + `PATH` in env (PR #251's `unsetenv_others: true` is too strict). Document this as a controlled relaxation.
- **Replay cache hooks**: `HECKS_LLM_REPLAY` and `HECKS_LLM_CAPTURE` env vars for differential fuzzer (i30). No fuzzer-specific code in the DSL.
- **Ruby-only in Stage A.** `hecks_life/` doesn't parse hecksagons (until PR #263's parser grows to cover `:llm`). Existing `adapter_llm.rs` stays untouched as parallel infra.

## Files

NEW:
- `lib/hecksagon/structure/llm_adapter.rb` (~120 LoC)
- `lib/hecksagon/dsl/llm_adapter_builder.rb` (~140)
- `lib/hecks/runtime/llm_dispatcher.rb` (~280)
- `lib/hecks/runtime/llm_dispatcher/claude_provider.rb` + `ollama_provider.rb`
- `lib/hecks/errors/llm_adapter_error.rb`
- `docs/usage/llm_adapter.md`
- `examples/llm_adapter/`
- Specs for each

MODIFY:
- `lib/hecksagon/dsl/hecksagon_builder.rb` (dispatch on `kind == :llm`)
- `lib/hecksagon/structure/hecksagon.rb` (reader + lookup)
- `lib/hecks/runtime.rb` (`#register_llm_adapter`, `#llm(name, **attrs)`)
- `lib/hecks/runtime/boot.rb` (`wire_llm_adapters`)

## Commit sequence (8)

1. `feat(hecksagon): add Structure::LlmAdapter value object`
2. `feat(hecksagon): add LlmAdapterBuilder DSL`
3. `feat(hecksagon): wire adapter :llm into HecksagonBuilder`
4. `feat(runtime): LlmDispatcher with provider switch + streaming`
5. `feat(runtime): token accounting via Spend.RecordCall`
6. `feat(runtime): LLM replay/capture fuzzer hooks`
7. `feat(runtime): boot-time llm-adapter registration + Runtime#llm`
8. `docs: llm adapter reference + example + migration note`

## LoC estimate

~1,680 production + ~870 specs + ~210 docs = ~2,760 total.

## Risks

- Streaming + Spend ordering on crash (partial records)
- Claude CLI auth env whitelist relaxes PR #251's security posture
- Prompt scaffolding leakage if guard code contains secrets — make scaffolding opt-in with metadata whitelist
- Budget races under concurrent dispatch (serialize via command bus)
- Fixture drift — add `HECKS_LLM_FIXTURE_STRICT` that errors on cache miss

## Relationship to i11

i11 PR 3 (Capability.InvokeAgent) depends on this. i23 should land before i11 PR 3.
i11 PR 1 (Tongue.Speak wired to Claude) can use `adapter :shell` directly, then migrate to `adapter :llm` in a follow-up — that's fine if PR 1 ships before i23. Ordering: i11 PR 1 first (simpler), i23, then i11 PR 3.
