# Terminal capability full wiring (follow-up to PR #263)

Source: plan by Agent a65afbf3 on 2026-04-22.

## Problem shape

PR #263 shipped `hecks-life run <file.bluebook>` + the terminal bluebook/hecksagon + the stdin-loop runner. But `hecks-life run capabilities/terminal/terminal.bluebook` today prints a banner and exits — because the terminal's REPL needs Speech, Mood, Heartbeat, Conversation, Musing state that lives in OTHER bluebooks. The run-loop dispatches `ReceiveInput` but those aggregates aren't in the composed Domain, so responses come back as `*silence*`.

Meanwhile `hecks-life terminal` (legacy path) still works via `run_terminal()` in `main.rs:803-828` which globs every `.bluebook` in `aggregates/` and merges them — "ambient shim."

## Decision: domain composition at LOAD time

**Extend the existing `subscribe "..."` directive** in `terminal.hecksagon` (and add `includes "..."` alongside for hard-dep edges). Teach `run.rs` to resolve + merge included domains.

Rejected alternatives:
- **Inline `boot_with` in the bluebook** — duplicates domain/infrastructure concerns; bluebook should describe `Session`, not neighbors
- **Separate `.bootset` file** — adds a third file kind per capability for one list of strings; fragments discovery
- **Convention scan** — fragile; can't express "start Heartbeat even though terminal never triggers it"

**PR #263 already stubbed `subscriptions: Vec<String>` on the hecksagon IR.** Nothing consumes them yet. Light them up.

Concretely, `capabilities/terminal/terminal.hecksagon` grows:

```
includes "Tongue", "Miette", "Awareness"   # mandatory — cascade dies without them
subscribe "Body"                            # optional — observability on Mood/Heartbeat
```

## Resolution + merge logic (in `run.rs`)

1. After `load_script` returns `(domain, hecksagon)`, read `hecksagon.subscriptions + hecksagon.includes`
2. Build an index once: walk `capabilities/`, `aggregates/`, `catalog/` — `HashMap<String, PathBuf>` keyed by `Hecks.bluebook "Name"` header. ~100ms cold, cheap.
3. Walk the dependency graph with cycle-guard (visited-set by name).
4. **Merge rules**:
   - `Domain.aggregates` concat with duplicate-name dedupe (first wins, warn)
   - `Domain.policies` concat (duplicates already handled by PR #256)
   - `Domain.fixtures` concat
   - `Domain.entrypoint` stays the root's
   - Hecksagon: `io_adapters`/`shell_adapters`/`subscriptions` concat; `persistence` root wins
5. `Runtime::boot_with_data_dir(merged_domain, ...)` unchanged — merge happens before boot, so repositories/policy_engine/projections all get populated off the whole graph.

**No Runtime API change required.** The whole feature is "Domain composition happens at load time."

## Missing cascade wire: LLM response population

Today `run_stdin_loop.rs` dispatches `ReceiveInput` → cascade fires `Speak` → `Spoken` emitted — but the Speech record's `response` field is never populated. Legacy terminal path (`main.rs:dispatch_hecksagon`) calls `adapter_llm::resolve(repo, state, ollama_config)` after dispatch. Shebang path doesn't.

**Fix**: add the same after-dispatch hook in `run_stdin_loop.rs`. Ollama config comes from a `:env` adapter on Tongue's hecksagon or the existing `find_world_ollama_config` helper.

## Heki path collision — real issue

Entrypoint's `data_dir` is `capabilities/terminal/information/` (inferred). But Tongue, Mood, Heartbeat expect to read/write `hecks_conception/information/tongue.heki` etc. With one merged runtime, ONE `data_dir` applies to all repositories.

**Quick fix (PR-scope)**: walk upward from the entrypoint file until a `*.world` or `information/` directory is found. ~20 LoC. Defers multi-store refactor.

**Long-term**: `Runtime::boot_with_data_dir` grows to accept `HashMap<AggName, PathBuf>` for per-aggregate data dirs.

## SIGINT handling

Currently Ctrl-C kills the process without `EndSession`. Install a `signal_hook`-style handler at top of `run_script` that sets an `AtomicBool shutdown`; loop checks after each iteration. Falls through to existing `EndSession` dispatch. ~30 LoC.

## Commit sequence (7)

1. `hecksagon: includes "..." directive on IR + parser` (~40 LoC)
2. `run: capability resolver` — index builder + cycle guard in `src/run_resolve.rs` (~150)
3. `run: compose merged Domain + merged Hecksagon in load_script` (~60)
4. `run_stdin_loop: call adapter_llm::resolve after ReceiveInput` (~40)
5. `run: SIGINT → EndSession graceful exit` (~30)
6. `capabilities/terminal/terminal.hecksagon: includes "Tongue", "Miette", "Awareness"` (~5)
7. `docs + deprecation note on adapter_terminal.rs + run_terminal`

## What breaks

- `hecks-life terminal <dir>` subcommand stays untouched (escape hatch)
- `adapter_terminal.rs` (45-line shim) stays untouched this PR; marked `DEPRECATED`
- Both die together in a follow-up after a week of dogfooding the shebang path

## LoC estimate

~350 net added Rust + 5 in hecksagon. No deletions this PR.

## Risks

1. **Cascade recursion / runaway loops** — composed domain brings `EncodeOnConversation` + `RespondOnSpoken`. Verify `policy_engine` has max-depth guard that trips cleanly with stderr warning. Add a cascade smoke test for Terminal.
2. **Boot order** — aggregates are order-independent (repositories are not live objects). Event order matters: `SpeakOnInput` must register before input fires. Since policies register in file-merge order and input is user-driven, fine. Document invariant.
3. **Heki path collision** — addressed with upward walk (above)
4. **Pidfile/port clashes on multiple terminals** — non-issue until mindstream lands on shared state
5. **LLM adapter keys** — missing keys should degrade gracefully to canned-response path (tongue.bluebook already has this at line 44)
6. **Name collisions** — two bluebooks declare `aggregate "Session"`? Dedupe keeps first, log warning. Long-term wants namespacing; out of scope.

## Key files

- MODIFY: `hecks_life/src/hecksagon_ir.rs` (add `includes: Vec<String>`)
- MODIFY: `hecks_life/src/hecksagon_parser.rs` (parse `includes "..."`)
- NEW: `hecks_life/src/run_resolve.rs`
- MODIFY: `hecks_life/src/run.rs` (call resolver before boot)
- MODIFY: `hecks_life/src/run_stdin_loop.rs` (adapter_llm hook + SIGINT)
- MODIFY: `hecks_conception/capabilities/terminal/terminal.hecksagon` (add includes)
