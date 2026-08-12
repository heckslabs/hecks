# Bug triage — 2026-08-10 audit, prioritized

_2026-08-11._ Every finding in [`2026-08-10-main-bug-audit.md`](2026-08-10-main-bug-audit.md),
reorganized into priority tiers. That file stays the source of truth for
detail (reproductions, code snippets, confidence); this file is an index and
an ordering.

## Methodology note

**This is a reorganization, not a re-verification.** Nothing here was
re-checked against current code — treat every item's status as "reported
2026-08-10, unconfirmed since." A day of dev/QA work has landed on top of
that snapshot (multiple QA sessions, the quality-control bluebook, entity
and query bug fixes — see `qa/reports/` and recent memory), so some of these
may already be fixed, or partially fixed. **Re-verify a finding before
starting work on it**, and check `qa/reports/` first in case it's already
tracked (and possibly already resolved) there under a different name.

Priority within a tier follows the source audit's own severity/confidence
signals (blast radius, silence, confirmed vs. likely/possible) — it is not a
new judgment call layered on top.

**ID scheme:** `S1`–`S3` and `H1`–`H14` are the source audit's own labels.
`M1`–`M29`, `L1`–`L24`, and `R1`–`R5` are assigned here (medium/low/Rust-parity
were unlabeled bullets in the source) — use these IDs when opening a fix or
cross-referencing `qa/reports/`.

75 findings total: 3 systemic, 14 high, 29 medium, 24 low, 5 Rust parity
divergences.

---

## Tier 1 — Data loss / migration integrity (fix first)

Silent, unrecoverable, or hard-to-detect data corruption. The source audit's
own #1 priority; nothing supersedes it.

| ID | One-line | File | Confidence | Status |
| --- | --- | --- | --- | --- |
| H1 | Entity commands run no argument gate — unknown args silently accepted, absent required args silently overwrite stored data with `nil` | `runtime/entity_interpreter.rb:27` | confirmed | **Fixed** — PR [#105](https://github.com/chrisyoung/hecksagain/pull/105), issue [#104](https://github.com/chrisyoung/hecksagain/issues/104) |
| H2 | Era mint isn't atomic — inner `@db.transaction` commits the whole mint early, releasing the advisory lock mid-flight; a later raise leaves a half-born era committed | `adapters/driven/postgres/lineage/head_compiler.rb:38` | confirmed | **Fixed** — PR [#165](https://github.com/chrisyoung/hecksagain/pull/165), issue [#163](https://github.com/chrisyoung/hecksagain/issues/163) |
| H3 | Deleting an era-migrated record resurrects it in the head view — the ancestor era's `save` row outranks the (untombstoned) delete forever | `adapters/driven/postgres.rb:192` | likely (static) | open |
| H4 | Rekey SQL is invisible to the human-approval digest — two different rekey SQLs produce the identical digest; an approved rekey can be edited post-approval and still mint | `translation/audit/approval_digest.rb` | confirmed | open |
| H5 | A dotted-member `compute` (e.g. `price.cents`) exempts the whole attribute from Layer-2's cross-execution equivalence gate — the gate whose entire purpose is to catch silent migration data loss produces zero violations on it | `translation/audit/layer_two.rb:56` | confirmed | open |

H1 and H2 are flagged in the source as the cheapest fixes (two missing
dispatch-order steps; drop or savepoint the inner transaction).

---

## Tier 2 — Systemic root causes (fix next — each retires a cluster)

Single points that fan out into multiple downstream bugs elsewhere in this
document. Fixing the root is expected to retire (or at least shrink) the
related medium-severity query findings noted below.

| ID | One-line | File | Confidence | Likely retires |
| --- | --- | --- | --- | --- |
| S1 | `render_value` collapses every non-symbol to `.to_s` on the IR wire, erasing type tags — `"007"→7`, `"true"→true`, `nil→""`, `eq: nil` compiles to `= ''` instead of IS NULL | `query_specification/common/comparators.rb:6` | confirmed | M1, M2, M4 (query-engine type/nil divergences) |
| S2 | `h[k.to_sym] \|\| h[k]` (5+ call sites) turns a stored `false` into `nil` via Ruby's `\|\|`-falls-through-on-false — `where(flags.active: false)` never matches | `field_path.rb:44` + 4 others | confirmed | any boolean-leaf query/`ne` bug not otherwise attributed |
| S3 | An aggregate's identity, free-form unless `pattern:`-constrained, flows unescaped into URLs and HTML — root of H10 and H12 | (see H10, H12) | — | H10, H12, L12 |

---

## Tier 3 — Security

Before the Rust web surface (or any operator tooling) takes more untrusted
exposure.

| ID | One-line | File | Confidence |
| --- | --- | --- | --- |
| H10 | Stored XSS via record id — the Rust web layer interpolates the aggregate id raw into link text/`href`/`<title>`/`<h1>`; every other value routes through `esc()`. Ruby presentation layer is unaffected. | `rust/host/src/web.rs:639,706` | likely |
| H11 | Session HMAC fails open on an empty `SESSION_SECRET` — unset, cookie/OAuth-state HMAC keys on a known empty string. Not currently exploitable (prod sets it from Secrets Manager) but fails open instead of refusing to boot, unlike every other required var. | `rust/host/src/web.rs:90` | likely (latent) |
| L12 | Record ids are HTML-escaped but never URL-encoded in `href`/`Location` — `&`, `+`, `?`, `#` in an id corrupt the link | `presentation/record_renderer.rb:75` | — |
| L20 | `rename-schema` interpolates `$(OLD)`/`$(NEW)` unsanitized into SQL — operator-only, but against prod RDS | `bin/project_deploy:1517` | — |

---

## Tier 4 — Wrong-answer / broken-route bugs on live paths

Confirmed or likely-live silent-wrong-answer bugs, grouped by subsystem.
Ordered high-severity first, then the medium-severity items most likely
related to (or exposed by) S1/S2 above.

**Query/routing (high):**

| ID | One-line | File |
| --- | --- | --- |
| H6 | `limit` applied before `offset` in the in-memory query port — `limit 10 offset 10` on 30 rows returns 0 rows instead of rows 11–20 | `ports/query/in_memory.rb:21` |
| H7 | Reference/entity query engine ignores `offset`, and reads fields directly instead of via `FieldPath.dig` — dotted `where`/`order_by` silently wrong on the *only* engine for entity queries | `runtime/query_interpreter.rb:78,149,261` |
| H8 | `seal_defaults` doesn't cover `one_of` closed sets — a documented-in-its-own-comment case boots clean, then refuses every create at dispatch | `bluebook/dsl/aggregate_builder.rb:228` |
| H9 | Meta-validator cache key omits read-model filters — a same-process reload after editing only a filter serves the stale one | `bluebook/meta_validator.rb:127` |
| H12 | Record ids containing `.` are unroutable — detail page, JSON view, and index link all 404 | `presentation/app.rb:70` |

**Query engine semantics (medium — likely related to S1/S2):**

| ID | One-line | File |
| --- | --- | --- |
| M1 | `ne` matches nil-held rows in memory; SQL `<>` excludes NULL | `ports/query/in_memory.rb:33` |
| M2 | `in` stringifies both sides, matching across types and `nil`↔`""` | `ports/query/in_memory.rb:37` |
| M3 | Default NULL ordering diverges between memory (SQLite convention) and Postgres | `query_specification/common/null_policy.rb:16` |
| M4 | Multi-numeric value object unwraps to first-numeric in one engine, whole hash in the other — `gt`/`lt` silently false on one side | `ports/query/in_memory.rb:74` vs `query_interpreter.rb:250` |
| M5 | `FieldPath#read` violates its "or nil, never raise" contract — raises `TypeError` through an Array | `query_specification/field_path.rb:45` |

**Expression sublanguage (medium):**

| ID | One-line | File |
| --- | --- | --- |
| M6 | Negated membership (`!names.include?(x)`) is inexpressible — all three spellings raise | `bluebook/expression/evaluator.rb:69` |
| M7 | Canonical-form normalisation rewrites string-literal *contents*, quote-blind | `bluebook/expression/canonical_form.rb:39` |
| M8 | `modulo` truncates floats and zero-checks before coercion → raw `ZeroDivisionError` | `bluebook/expression/resolver.rb:201` |
| M9 | Raw `TypeError`s cross the `DomainRefusal` boundary | `resolver.rb:212` / `evaluator.rb:72` |

**IR round-trip losses (medium):**

| ID | One-line | File |
| --- | --- | --- |
| M10 | `formerly_known_as` and chapter-level `@ports` are ivars absent from `to_h` — lost on IR round-trip | `bluebook/ir/bluebook.rb:69` |
| M11 | `correlates_by` maps `nil → ""` on the wire | `bluebook/ir/process_manager.rb:113` |

**DSL sealing / assembly (medium):**

| ID | One-line | File |
| --- | --- | --- |
| M12 | Duplicate attribute names both survive into IR — nothing refuses them | `bluebook/dsl/attribute_collector.rb:34` |
| M13 | An entity's attribute types are never resolved as references — undeclared type boots clean | `meta_validator/judge.rb:260` |
| M14 | Entity query hops are not sealed — `where` through an undeclared aggregate boots clean | `bluebook_builder.rb:195` |
| M15 | Object-literal decoders corrupt on an embedded `"`; under Ruby ≥3.4 every object-literal default/binding decodes to `{}` | `marks.rb:171` / `meta_validator/shapes.rb:94` |
| M16 | `plural`/`singularize` are not inverses for `-es` — `has_many Boxes` refuses a phantom `Boxe` | `naming.rb:61` + `aggregate_builder.rb:88` |

**Runtime (medium):**

| ID | One-line | File |
| --- | --- | --- |
| M17 | A composite-identity creating command that doesn't redeclare its heads as attributes persists them as `nil` | `runtime/instance.rb:95` |
| M18 | `Identity.of` raises `NoMethodError` on a non-string identity part where a refusal belongs | `runtime/identity.rb:63` |
| M19 | In-process vs. SQLite read-model paths diverge on missing heads/root/join scope | `read_model_interpreter.rb:78` vs `sqlite/projection.rb:39` |
| M20 | `@reaction_depth` is a plain (non-thread-local) ivar on a thread-shared dispatcher — matches the known Puma-concurrency bug class | `dispatcher.rb:165` |

---

## Tier 5 — Ops & translation correctness

| ID | One-line | File |
| --- | --- | --- |
| H13 | `make deploy` always exits non-zero for Shared-mode domains — the unautomated `mint-era` stub `exit 1`s after a successful `sam deploy`, training operators to ignore red deploys | `bin/project_deploy` |
| H14 | Generated `scaffold-translation`/`translation-audit` targets open a real prod SSM tunnel, then silently scaffold/audit the developer's *local* DB instead | `bin/project_deploy:1389` |
| M26 | Layer 1 checks lifecycle values against targets only, not `ModelCheck.full_states` — a valid `from:`-only state blocks the mint | `translation/audit/layer_one.rb:24` |
| M27 | Sequential in-place rename loses data on swap/chain renames (`{a:b,b:a}` on `{a:1,b:2}` → `{a:1}`) — Layer 2's reference, so the compiled SQL agrees and it mints silently | `ports/persistence/lineage.rb:92` |
| M28 | Adding Google OAuth to a live stack deadlocks `make deploy` — pre-deploy `mint-era` queries outputs the deploy hasn't created yet | `bin/project_deploy:1818` |
| M29 | RDS master passwords may contain `%`, invalid in libpq's URI parser — ~29% of 32-char passwords | `bin/project_deploy:816` |
| L15 | `bin/project` missing the executable bit | — |
| L16 | `bin/present --port=8080` (equals form) silently ignored; `-p abc` binds an ephemeral port | `bin/present:64` |
| L17 | `bin/evolve`'s `option` swallows a following flag as its value | `bin/evolve:48` |
| L18 | `bin/evolve rename` has no rescue/ensure — a mid-cascade raise leaves `syntax.bluebook` half-renamed | `bin/evolve:63` |
| L19 | `bin/stores` on a nonexistent domain path exits 0 with no output | `bin/stores:14` |
| L13 | `reset!` on a lineage-provisioned journal (FORCE RLS, no DELETE policy) silently deletes zero rows | `adapters/driven/postgres.rb:225` |

---

## Tier 6 — Harness / test-quality blind spots

Fixing these doesn't fix a product bug directly, but it's why several of the
above stayed hidden behind a green suite — and why fixes to them need new
coverage, not just a patch.

| ID | One-line | File |
| --- | --- | --- |
| M21 | Three shipped framework aggregates (RoleAssignment, RoleTransition via composite id; ConsoleSettings `Replace*` via `list_of`) are half-unfuzzable — every acting step refused, zero events | `fuzzing/sequence_generator/outcome_tracker.rb:14` + `step_builder.rb:36` |
| M22 | `saga_advances_follow_declared_handlers` passes vacuously — the log copies `from:`/`to:` from the handler it's then checked against | `fuzzing/properties.rb:61` |
| M23 | The query oracle masks refusal-shaped divergence — both engines share one `begin`, an entry where either raised is skipped | `fuzzing/replay.rb:49` |
| M24 | `shrink_arguments` never accumulates drops — each accepted drop reverts the previous ones | `bin/fuzz:139` |
| M25 | `RoleTransition` has an absorbing `revoked` state — a revoked pair can never be re-granted, contradicting its own header comment | `framework/bluebook/governance.bluebook:84` |
| R1 | 6 events differ on the full corpus (not the 3 pinned fixtures) — Rust emits `nil` for an omitted optional arg where Ruby omits the key | `rust/src/kernel/json.rs:178` |
| R2 | Refusal counts diverge, Ruby 94 vs Rust 131 — 37 "query steps not generated yet" placeholders shift every later index | `rust/src/kernel/cli.rs:76` |
| R3 | Dispatch-order inversion — Rust checks role/references before VO invariant/admits/pattern; Ruby is the reverse. Same bad input → different refusal per runtime. | `rust/project/registry.rb:116` |
| R4 | Empty-string identity component accepted by Rust, rejected by Ruby — real persisted-state divergence | `rust/src/kernel/*` (`to_id_component`) vs `Identity.of` |
| R5 | `cargo build --features banking` fails to compile (mutually-exclusive domain features unmarked); plus latent codegen landmines (a domain named `version`/`edition`/`path`/`default`, or a description with `#{`/`#@`/control chars) | `Cargo.toml`, `bin/project_rust:160` |

The recorded Rust-parity status ("35/35 instances") only holds for the 3
pinned fixtures — R1–R4 surface only against the full corpus.

---

## Tier 7 — Low severity (cosmetic, latent, or gated behind untriggered input)

Everything from the source audit's Low section not already placed above.

| ID | One-line | File |
| --- | --- | --- |
| L1 | `catch_up!` only enforces history consistency under the exact symbol `:strict` | `ports/projection.rb:44` |
| L2 | Chained non-root heads are still declaration-order dependent one level deeper than the root-first fix reached | `runtime/read_model_interpreter.rb:55` |
| L3 | `Dir[…].first` reproduces the multi-file wrong-source bug `EraCheck` already fixed elsewhere; only reached from a spec today | `runtime/era_guard.rb:29` |
| L4 | `sign_of` returns `-1` for any op without a sign; unreachable today | `runtime/command_rules/arithmetic.rb:85` |
| L5 | `match_transition` falls back to `matches.first` when no `from:` admits the state; dead code, zero callers | `bluebook/ir/lifecycle.rb:58` |
| L6 | A multi-column `one_of` is admitted on its first column only | `runtime/value/admission.rb:14` |
| L7 | `one_of` member values are stringified in `to_h` (`Integer 1 → "1"`) | `bluebook/ir/value_object.rb:57` |
| L8 | Possessive-quantifier check doesn't skip character-class interiors — `[*+]` wrongly refused, `a{2}+` wrongly admitted | `bluebook/pattern_subset.rb:88` |
| L9 | `validate_command!` accepts creating-command names a `Handle` can't dispatch → `NoMethodError` instead of 404 | `facade/json_door.rb:85` |
| L10 | `run_query` omits `JSON::ParserError` from its rescue list — a malformed list-of-VO query 500s instead of a 422 | `presentation/app.rb:200` |
| L11 | A record whose id equals a command/query name shadows its own detail page | `presentation/app.rb:106` |
| L14 | SQLite/D1 store literal `"null"` text where Postgres stores SQL NULL — decodes the same today, diverges under a future `IS NULL` check | `adapters/driven/sqlite.rb:86` / `d1.rb:136` |
| L21 | `f64→i64` cast saturates silently where Ruby keeps a Bignum | `rust/src/kernel/json.rs:108` |
| L22 | `Int + Int` uses plain `+` (debug panic / release wrap) where Ruby promotes to Bignum | `rust/src/kernel/expr.rs:239` |
| L23 | `nest()`'s `.as_object_mut().unwrap()` panics (500) on a scalar/group path-prefix collision | `rust/host/src/web.rs:562` |
| L24 | Post-accept redirect id is `mutations.last().last()`, which can belong to a cascaded reaction's aggregate, not the form's target | `rust/host/src/web.rs:748` |

---

## Cleared (no action — carried forward from source audit)

SQL identifier quoting and JSONB path building in the Postgres adapter;
`search_path` schema isolation; ORDER BY tiebreakers; the `Handle`
composite-identity fix; `JsonDoor` wiring; the Ruby presentation layer's
HTML escaping; comma-bearing `contains`; `AppendOnly#save`'s shallow dup;
the `rust_conformance` comparison logic itself.

---

## Harness baseline (from the source audit, unchanged)

| Harness | Result @ 2026-08-10 |
| --- | --- |
| RSpec | 1170 examples, 0 real failures |
| Property fuzzer (`bin/fuzz --seeds 60 --steps 40`) | clean |
| IR model checker (`bin/model_check`) | clean |
| Rust `cargo test` | passes, zero unit tests exist |

Re-run before trusting this baseline for any fix — this branch
(`fix/language-bluebook-validation`) currently has 53 unrelated pre-existing
`rspec` failures as of 2026-08-11 that this snapshot predates.
