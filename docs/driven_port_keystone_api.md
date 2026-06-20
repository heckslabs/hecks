# Driven-port keystone — LOCKED API (slice 1: `llm` only)

Status: LOCKED for the first slice. Scope is the `llm` adapter end-to-end
only. `signal` is NOT retired in this slice (families keep `signal :effect`).
`claude_tool` / `mcp` / `web_tool` / `sms` / `exec` / `shell` are untouched.

This doc is the contract the rest of the arc builds against. It records the
four things the keystone needed to pin: (1) the primary-adapter synchronous
wait signature, (2) the out-of-process handler protocol, (3) the family
shape, (4) the verdict / idempotency / dead-letter contract.

---

## 0. The model in one paragraph

ONE category (Cockburn driven/secondary ports), TWO interaction styles:
persistence = Evans synchronous Repository (in-process, inline); every other
effect = Vernon async domain event (emit event -> handler off-core -> result
re-enters as a verdict command). The CORE is the sole synchronous pure
function `(own hydrated state + command) -> (new state + emitted
events/effects)`; it NEVER blocks. The agent's WAIT is a PRIMARY/driving
adapter concern at the serve/dispatch boundary: it turns an inbound request
into a wait-for-result by draining the effect to quiescence inline. Driven
ports never block.

---

## 1. Primary-adapter synchronous wait — `drain_outbound_to_quiescence`

New method on `Runtime` (hand-editable file `rust/src/runtime/reaction.rs`'s
sibling, or `mod.rs`; NOT generated). Signature:

```rust
/// Primary-adapter synchronous wait. Reuses run_host's primitive
/// (Claim -> exec handler (bounded, BLOCKING, verdict-capturing) ->
/// dispatch verdict -> the verdict re-enters the core, which may emit
/// more effects) and loops to QUIESCENCE. Returns the number of
/// deliveries drained. Bounded by max_iterations + a per-handler
/// timeout budget; exhaustion dead-letters the delivery (MarkFailed +
/// last_error) and the boundary returns a failure result.
///
/// Claims ONLY verdict-bearing deliveries (success_command non-empty).
/// Fire-and-forget deliveries (both verdict commands empty, e.g.
/// voiced_by/tts) are LEFT for the detach-spawn pump
/// (pump_outbound_events) — never claimed here, so a slow playback
/// never blocks the wait, and a verdict k=v is never discarded to
/// /dev/null by the detach pump's Stdio::null().
///
/// Handler-less deliveries are LEFT PENDING (not claimed, not failed)
/// — mirrors pump_outbound_events, NOT run_host_pass (whose
/// mark_failed-on-handler-less would loop forever under a quiescence
/// wrapper).
pub fn drain_outbound_to_quiescence(&mut self) -> usize;
```

Gate: the boundary calls this ONLY when `HECKS_REPLY_OOP_LLM` is set
(slice-1 gate name). With the gate OFF, the existing in-process path runs
unchanged (the in-process `resolve_llm_adapters` LlmAdapter-struct path).

Drain-to-quiescence driver (the one genuinely new design judgment):
  loop up to MAX_ITERS:
    pending = OutboundEvent rows where status==pending
             AND success_command != ""            (verdict-bearing only)
             AND adapter has a built handler binary (else skip, leave pending)
    if pending empty -> break (quiescent)
    for each: Claim (given status==pending; err -> skip, another drainer took it)
              exec handler BLOCKING (run_host::exec::run_handler) bounded by timeout
              verdict = success_command if exit 0 else failure_command
              dispatch verdict (threads stdout k=v pairs + source_id) -- RE-ENTERS CORE
              MarkDelivered (reached a verdict == handled)
              (the verdict dispatch may emit a NEW effect -> new OutboundEvent
               -> next loop iteration drains it: this is the to-quiescence part)
  on timeout/exec error within budget -> MarkFailed (last_error) -> dead-letter

Correlation: "which deliveries this dispatch must await" = every pending
verdict-bearing delivery with a built handler, transitively (the loop). For
slice 1 the inline drainer awaits ALL such deliveries (the dispatch is
single-threaded and the proof aggregate emits exactly one). Poll-by-id is the
future refinement when a handler must run in a separate warm host.

---

## 2. Out-of-process handler protocol (REUSED verbatim from run_host)

`rust/src/run_host/exec.rs::run_handler(path, payload, env) -> HandlerOutcome`
  - STDIN : the OutboundEvent.payload JSON (the emitted event's data).
  - ENV   : per-adapter config folded from `.world` via
            `runtime/adapter_env.rs::map_config` under canonical
            `<FAMILY>_<FIELD>` names (e.g. `LLM_BACKEND`, `LLM_MODEL`).
  - STDOUT: verdict `k=v` lines, parsed in order by `parse_pairs`.
  - EXIT  : 0 = success branch, non-zero = failure branch.

This is the VERDICT-CAPTURING protocol (payment/stripe shape), NOT the
tts self-ack shape. The inline drainer (not the handler) dispatches the
verdict and MarkDelivered. The handler is a pure k=v emitter: it does the
impure work, prints the verdict, exits with the branch code. Idempotency is
the drainer's Claim guard, not the handler's concern (but a future handler
that itself has side effects must dedup on HECKS_DELIVERY_ID).

### The llm handler's verdict key (LOCKED)

The llm handler emits exactly:

```
response_text=<the completion>
```

`response_text` is the LOCKED verdict key. The binding's success_command is
the verdict command whose attribute receives it (see family shape below).

---

## 3. Family shape — `adapters/llm/llm.family` (mirrors adapters/tts)

```ruby
Hecks.family "llm" do
  verb   "completed_by"        # the how-verb hung off the aggregate FQN
  signal :effect                # KEPT for slice 1 (signal retired in a later slice)
  field  :backend               # test | claude | ollama  (per-deployment in .world)
  field  :model
  field  :max_tokens
  field  :prompt_template       # {{placeholder}} prompt; substituted from the event payload
  produces :response_text       # the verdict contract a conforming handler MUST emit
end
```

Adapter `adapters/llm/test-llm.adapter`:

```ruby
Hecks.adapter "TestLlm" do
  family  "llm"
  handler "adapters/llm/llm-handler"
end
```

Handler `adapters/llm/llm-handler` (Rust, standalone, TestProvider
semantics): reads the event payload JSON on stdin, builds the substituted
prompt, computes SHA-256, looks up the fixture (or emits the deterministic
lenient-miss `[test-provider:unknown-prompt sha256=<digest>]`), prints
`response_text=<completion>`, exits 0.

### Binding form (effect-with-verdict — the OOP path)

```ruby
Hecks.hecksagon "Dream" do
  Dream::Dream.completed_by("TestLlm", on: "DreamSeeded") do
    success "Dream.RecordCompletion"   # verdict command; receives response_text
    failure "Dream.MarkFailed"         # forward-compensation verdict (dead-letter surface upstream)
  end
end
```

The success verdict command `RecordCompletion` declares `attribute
:response_text` and `then_set`s it — so the handler's `response_text=` k=v
threads straight in. This makes gate-ON land the IDENTICAL value the in-process
`response_into_attr` path lands gate-OFF (both = TestProvider(prompt)).

This slice proves against the EXISTING inline binding form; no new
`Hexagon.Binding response_into` field is added.

---

## 4. Verdict / idempotency / dead-letter contract

- VERDICT: success_command on exit 0, failure_command on non-zero. Reached a
  verdict == delivery is HANDLED -> MarkDelivered (terminal). "delivered"
  means handled, not approved. Mirrors run_host/pump policy.
- IDEMPOTENCY (at-least-once + idempotent): dedup on the delivery id.
  OutboundEvent.Claim carries `given status == pending`, so a second
  drainer/daemon Claim ERRORS and skips. delivery_id =
  `source_type::source_id::event::adapter`, so a re-emit of the same event
  for the same adapter is the SAME delivery (idempotent recording, already
  enforced by record_effect_outbound). A replayed drain after MarkDelivered
  finds status != pending -> Claim errors -> handler not re-exec'd ->
  verdict landed exactly once. (Effectively-once.)
- DEAD-LETTER (compensate-forward, no distributed rollback): a handler
  exec error or timeout within budget -> MarkFailed(last_error) returns the
  delivery to pending for a bounded retry. After the retry budget is
  exhausted, the delivery dead-letters to a human surface (the fibroblast
  decline-to-human discipline); the failure_command (forward compensation)
  is the domain-level decline. NO rollback is attempted. (Dead-letter is
  DEFINED here; slice-1 proof is happy-path + equality + no-block +
  idempotency only.)

---

## 5. What slice 1 does NOT change

- `signal` stays on every family (retired in a later slice).
- The in-process `llm_dispatcher.rs` + `resolve_llm_adapters` stay as the
  gate-OFF fallback. The gate-ON path is the new effect-binding + drainer.
- `reaction.rs` / `.frag` are NOT hand-edited. record_effect_outbound
  already records the OutboundEvent for any effect binding, so no specializer
  change is needed for the keystone.
- No other adapter is migrated.
