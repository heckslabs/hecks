# Plans Index — Ready-to-Implement

Detailed implementation plans produced during the 2026-04-21/22 session.
Each file under this directory is a compact handoff: decisions already
made, next commits spelled out, key files named.

**Start here if you're a fresh session.** Read this index, pick an item,
read its plan file. The plans were produced by careful investigation
agents — trust the decisions, don't re-derive them.

## Open plans (implementation not yet started, or only partially)

| File | Inbox | Status |
|---|---|---|
| [i3_moment_consciousness.md](i3_moment_consciousness.md) | i3 | PR-0 + PR-a shipped; PR-b..PR-f remain |
| [i7_parsed_hecksagon_world_dsl.md](i7_parsed_hecksagon_world_dsl.md) | i7 | Rust hecksagon parser shipped; Ruby allow-list loader + world DSL remain |
| [i11_pr1_tongue_speak.md](i11_pr1_tongue_speak.md) | i11 | PR 0 shipped; PR 1 unblocked |
| [i20_web_ontologies_preseed.md](i20_web_ontologies_preseed.md) | i20 | Not started; schema.org primary, nursery-stub handoff to i27 curation |
| [i23_llm_adapter.md](i23_llm_adapter.md) | i23 | Refined 2026-04-22 (Stage A Ruby, ~2600 LoC, 9 commits); prereq for i11 PR 3+ |
| [i25_loss_function.md](i25_loss_function.md) | i25 | Not started |
| [i27_nursery_viability.md](i27_nursery_viability.md) | i27 | Refined 2026-04-22 as NurseryHealth capability (7 commits, ~900 LoC) |
| [i28_adapter_keyword.md](i28_adapter_keyword.md) | i28 | Recommends Option D: upgrade `external` with `adapter:` kwarg (or close as no-op) |
| [i30_differential_fuzzer.md](i30_differential_fuzzer.md) | i30 | Not started |
| [i31_expand_parity_coverage.md](i31_expand_parity_coverage.md) | i31 | Not started; nursery sweep (3 commits, ~240 files rewritten) to flip soft→hard |
| [i36_computed_views.md](i36_computed_views.md) | i36 | Not started; architectural (projection DSL + 10 commits) |
| [i37_python_removal.md](i37_python_removal.md) | i37 | Phase A shipped (PR #272); Phase B+ unblocked |
| [i42_catalog_dialect.md](i42_catalog_dialect.md) | i42 | Not started; retires 4 shape-only aggregates from PR #267 |
| [i43_cross_bluebook_behaviors.md](i43_cross_bluebook_behaviors.md) | i43 | Not started; additive `.behaviors` DSL extension (10 commits) |
| [terminal_capability_wiring.md](terminal_capability_wiring.md) | — | Follow-up to PR #263 |

## Dependencies between plans

- **i11 PR 1** uses PR #251's shell adapter + PR #259's Spend/CircuitBreaker. Unblocked.
- **i11 PR 3+** (Capability.InvokeAgent) depends on **i23** (`adapter :llm`).
- **i30** differential fuzzer depends on the Ruby-side heki reader (tiny unstarted follow-up).
- **i3 PR-c** is the big one — Moment aggregate + mindstream refactor + sleep gating all in one.
- **i37 Phase B** (sweep shell scripts) unblocked; just mechanical.
- **Terminal capability wiring** depends on nothing — pure Rust + hecksagon parser extensions.

## Where the big shipped work lives

Commits on `main` landed today (~40 PRs); notable ones referenced by these plans:

- **PR #245** — rename `.hec` → `.hecksagon` / `.world` / `.bluebook`
- **PR #251** — hecksagon `adapter :shell` (Ruby runtime)
- **PR #259** — i11 PR 0 (Spend + CircuitBreaker aggregates)
- **PR #261** — i3 PR-0 (BodyPulse extraction)
- **PR #263** — shebang runtime + terminal adapter port (foundational)
- **PR #265** — i24 DSL collapse (resolves i1 + i2)
- **PR #271** — i3 PR-a (Heart + Breath + Circadian)
- **PR #272** — i37 Phase A (hecks-life heki subcommands)
- **PR #273** — first shebang migration (`status.sh` → `capabilities/status/`)
- **PR #274** — fix tick-during-sleep bug (i40 filed for proper fix)

## Memories worth reading alongside

- `~/.claude/projects/.../memory/feedback_never_preempt_exemptions.md` — antibody commit-marker rule
- `~/.claude/projects/.../memory/feedback_session_2026_04_22.md` — session reflection: what worked, what didn't
