# Changelog

All notable arcs land here, newest first. Dates are ISO (YYYY-MM-DD).
For the running, test-anchored feature list see `FEATURES.md`.

## 2026-05-12 — Macrophage + Tools arc

### Added
- **`Tools` bluebook** (`framework/tools/tools.bluebook`) — six first-class tool-invocation commands (`Bash`, `Edit`, `Read`, `Update`, `Grep`, `Glob`) ; each mints a per-invocation aggregate and emits an event the runtime can react to. See i551
- **`:claude_tool` adapter family** (`framework/adapter_families/claude_tool.hecksagon`) — bluebook-first declaration of the bridge from a `Tools.X` dispatch back to the underlying tool execution. Sibling to `:sms`, `:tts`, `:llm`, `:compute`
- **`invoke_claude_tool` behavior kind** (`framework/behavior_kinds/invoke_claude_tool.hecksagon`) — declarative contract for the kernel hook: `:tool`, `:result_into`, `:description` trigger attribute
- **`claude_tool_dispatcher.rs` kernel hook** (`rust/src/runtime/claude_tool_dispatcher.rs`) — six native primitives ; end-to-end `Tools.Bash` dispatch actually runs the shell via `std::process::Command`. See i556
- **Four design principles** locked in `docs/design/principles-2026-05-12.md` — "it just works · wiring is override · domain doesn't hibernate · domain composes, adapter runs"

### Changed
- **Enforcer → Macrophage** (rename + dense restructure) — the immune-system metaphor sharpened: macrophage fires at write-time, antibody fires at commit-time + CI. The former `MacrophageCheck` aggregate folded in as a child `Check` entity. New child entities: `Violation`, `Complaint`, `FixturesViolation`. No-primitive-envy sweep wrapped every primitive in a typed value-object. See i553
- **No-primitive-envy hygiene** extended to `Macrophage`, `Immunity`, `Antibody`, `dispatch_audit`, and `mindstream`
- **Parser auto-list heuristic retired** — both Ruby (`ruby/hecks/dsl/attribute_collector.rb`) and Rust (`rust/src/parse_blocks.rs`) parsers no longer infer `list_of(X)` from a pluralised attribute name. Explicit `list_of("X")` is now the only way. See i550

### Fixed
- **Companion-file ratchet false-positive** — `.git/hooks/pre-commit` now subtracts `-aggregate` matches from `+aggregate` matches in the staged diff so description-text edits stop flagging pre-existing aggregates as new. See i553

### Removed
- **10 dead-path entries** swept from the `exempt_registry`

### Inbox (filed this arc)
- i529 — singleton fallback
- i550 — explorer codegen
- i551 — `:claude_tool` adapter family
- i552 — Claude calls StoreHouse
- i553 — macrophage rename + CI parity by construction
- i554 — retired
- i555 — no-VOs-outside rule
- i556 — kernel hook
- i557 — Phase-2 framework runtime
- i559 — worktree-isolation hook bug
