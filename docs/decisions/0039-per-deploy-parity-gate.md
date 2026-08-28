# A per-deploy Ruby/Rust parity gate — and the honest news about banking's own current artifact

**Status:** Shipped. `bin/project_deploy`'s generated `deploy:` target now runs a new `verify-parity-<LogicalId>` target — `bin/rust_conformance <domain> spec/corpus/<domain>.json $(WASM)` — right after `build-<LogicalId>` produces `$(WASM)` and before `sam deploy` ever runs. `spec/project_deploy_parity_gate_spec.rb` proves both halves: the generated Makefile actually wires the target in, and the underlying mechanism (`bin/rust_conformance`'s own exit code) genuinely fails on a real, deliberately-mismatched artifact and passes on a real match.

## The gap this closes

`bin/project_deploy` had zero hook into any Ruby/Rust conformance check. Parity was proven only against CI's fixed test corpus (`spec/rust_conformance_spec.rb`'s own curated fixtures, `spec/rust_conformance_fuzz_spec.rb`'s generated sequences) — completely decoupled from what a real `sam deploy` actually shipped. A domain's checked-in `rust/src/generated/` tree could silently drift out of sync with its own Ruby source (exactly the staleness Phase 6 found and fixed for `examples/pizzas`) and nothing would refuse the deploy.

Now it does: `verify-parity-<LogicalId>` runs the real differential harness against the *specific compiled artifact about to ship* ($(WASM), the exact file `build-<LogicalId>` just produced), not a corpus-wide `cargo build`'s own separate binary. `bin/rust_conformance` exits non-zero on any mismatch, and the Makefile target lets that propagate uncaught — `make deploy` stops before `sam deploy` runs, the same way a failing build already would.

## What happens if a domain has no pinned script yet

`spec/corpus/<domain>.json` (the same fuzzer-replay script shape `bin/fuzz`/`bin/run` already use) is what the gate compares against. A domain without one gets a loud, visible warning and the deploy proceeds anyway — never a silent skip that reads as coverage it doesn't have. Every currently-deployable domain (`banking`, `compliance`) already has one.

## The honest finding this surfaced immediately: banking's own current artifact would NOT pass

Building `examples/banking`'s real `.wasm` (`bin/project_wasm examples/banking`) against the CURRENTLY CHECKED-IN `rust/src/generated/banking/` tree and running it through `bin/rust_conformance examples/banking spec/corpus/banking.json <wasm>` for real finds a genuine mismatch — confirmed directly, this session. Every single divergence traces to an already-catalogued, already-documented gap, nothing new:

- `"unknown command \"Banking::Account.CorrectFee\""` — the pre-existing `corrects` construct gap in banking's own generated Rust (noted repeatedly this session; regenerating banking picks it up but was deliberately not committed this round — see ADR 0037's own "Finding 2" note on why a full banking regen carries its own separate, unrelated scope).
- Multiple `"named/declared query ... is not generated for this domain"` — the Phase 10 backlog's own structural refusal boundary (offset/cursor/consistency/authorization/null_semantics/group_by/count/median).
- `"PersonName.given: missing from JSON args"` vs. Ruby's richer `"... was not given ... — it takes ..."` — ADR 0037's own Finding 3 (missing-argument wording), not yet fixed.

**This is the gate working exactly as designed, not a bug in it.** Phase 8's whole point was converting "our synthetic fixtures pass" into "this exact artifact is proven equivalent" — and the honest answer, checked for real, is that banking's own checked-in artifact is not currently equivalent, for reasons already tracked elsewhere in this plan (ADR 0037, Phase 10). A real `make deploy` for banking today would correctly refuse until either banking's generated Rust is refreshed to pick up the fixes already landed, or the specific query/read-model shapes it needs are added to the codegen backlog.

## Verification

Both halves proven directly (`spec/project_deploy_parity_gate_spec.rb`, `io: true`):
1. **Structural** — a scratch `AwsLambda`-deployable fixture domain, generated for real through `bin/project_deploy`, has its Makefile text checked for the `.PHONY`/target declaration, the `bin/rust_conformance`/`$(WASM)` invocation, the `deploy:` wiring, and the loud-skip fallback wording.
2. **Functional** — the plan's own explicit ask ("confirm the new deploy-time gate actually blocks a deliberately-broken artifact... before trusting it in production"): real `.wasm` artifacts built for `examples/roster` and `examples/pizzas`, then `bin/rust_conformance` run with roster's own proven-clean fixture (`spec/corpus/rust_conformance/roster.json`) against (a) roster's own matching artifact — passes — and (b) pizzas' unrelated artifact — a deliberately wrong pairing, guaranteed to diverge — fails, with "mismatch" in its own output.
