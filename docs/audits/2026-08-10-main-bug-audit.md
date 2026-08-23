# Bug audit — `main` @ `a9236cd`

_2026-08-10._ A line-by-line correctness review of the whole codebase: every
`.rb` under `lib/`, all 27 `bin/` scripts, and the hand-written + generated
`rust/`. Ten parallel deep-read passes (one per subsystem), cross-checked
against the project's own harnesses, with every load-bearing finding
re-verified by running the code. No files were changed by the audit.

This is a snapshot, not a work log — findings are described where they live,
with a `file:line`, a severity, a confidence, and (where one exists) a
reproduction. Fixing any of them is separate work.

## How to read this

- **Confirmed** = verified by running the real code (snippet or harness
  output reproduced during the audit). **Likely/possible** = established by
  reading both sides of the contract but not run live (usually because it
  needs a real Postgres, a concurrency window, or a bluebook no corpus
  member writes yet).
- Severity is about blast radius and silence: a **high** silently corrupts
  data, returns wrong answers, or opens a security hole on a live surface. A
  **low** is latent, loud, cosmetic, or gated behind an input nothing
  currently produces.

## Harness baseline

Run against `main` in a clean detached worktree:

| Harness | Result |
| --- | --- |
| RSpec (`bundle exec rspec`) | 1170 examples, **0 real failures** |
| Property fuzzer (`bin/fuzz --seeds 60 --steps 40`) | clean — banking, pizzas, grammar |
| IR model checker (`bin/model_check`) | clean — no dead states / unreachable steps |
| Rust `cargo test` | passes, but **zero unit tests exist** |

The one RSpec failure seen in a full run — `schema-evolution.md`'s doctest,
`database "hecksagain_doctest_grange" already exists` — is **environmental**:
`spec/support/doctest.rb` uses a fixed global Postgres DB name, so two
concurrent checkouts on one machine race. It passes in isolation. (Worth
fixing: the fixed name should carry a per-process suffix.)

**The green suite is the headline risk, not the reassurance.** The adapter
agreement gate, the fuzzer's query oracle, and the pinned Rust conformance
fixtures were each curated around inputs that happen not to diverge. Several
high-severity bugs below sit squarely in those blind spots and were
confirmed live anyway.

---

## Systemic root causes

Three single points cause findings in multiple subsystems. Fixing the root
retires the whole cluster.

### S1 — `render_value` erases types on the IR wire

`lib/hecksagain/query_specification/common/comparators.rb:6`

```ruby
def self.render_value(value) = value.is_a?(Symbol) ? ":#{value}" : value.to_s
```

Every non-symbol collapses to `to_s`, discarding the type tag. On decode the
type is re-guessed, so `"007" → 7`, `"true" → true`, `nil → ""`, and a
literal string `":x"` is indistinguishable from symbol `:x` (an arg
reference). Confirmed to produce **silent wrong query answers** in three
subsystems: query IR, expression IR, and every bluebook's meta-validator
assembly (`assembly/marks.rb:197` — `where code == "007"` returns 0 rows
against a record whose code really is `"007"`). `eq: nil`, a supported
IS-NULL query, compiles to `= ''`.

### S2 — `h[k.to_sym] || h[k]` turns a stored `false` into `nil`

The idiom appears in at least five places:
`query_specification/field_path.rb:44`,
`bluebook/expression/resolver.rb:215`,
`runtime/query_interpreter.rb:160`,
`runtime/identity.rb`, `translation/audit/unfed_report.rb:35`.

When the symbol key holds `false`, `false || h[k]` falls through to the
(absent) string key and yields `nil`. The seal admits boolean leaves
(`TrueClass`/`FalseClass` in `SCALAR_PRIMITIVES`), so
`where("flags.active" => false)` never matches a genuinely-`false` row and
`ne` answers wrongly. No cross-engine oracle catches it because every
in-process engine shares the idiom.

### S3 — identity values reach URLs / HTML unescaped

An aggregate's identity is built from user-supplied command arguments and is
free-form unless the value object declares a `pattern:`. That value flows
verbatim into a URL path segment (Ruby router) and into HTML (Rust web
layer). Same root, two exploited surfaces — see H10 and H12.

---

## High severity

### H1 — Entity commands run no argument gate → silent nil-overwrite data loss

`lib/hecksagain/runtime/entity_interpreter.rb:27` · confirmed

`DISPATCH_ORDER` omits `refuse_unknown_arguments` and
`refuse_absent_arguments`, on a comment claiming an entity "inherits its
aggregate's own gate." Nothing on the entity dispatch path
(`Dispatcher#dispatch → EntityInterpreter#call`) ever runs that gate.

Verified against the banking corpus:
- `Banking::Account.LedgerEntry.Reverse` with `bogus_arg: 123` → silently
  accepted.
- `Reverse` **without** its declared `narrative` → accepted;
  `then_set :narrative, to: :narrative` resolves the absent arg to `nil`
  and **overwrites the stored narrative with nil**. Persisted data loss, no
  refusal.

### H2 — Era mint is not atomic (nested transaction commits it early)

`lib/hecksagain/adapters/driven/postgres/lineage/head_compiler.rb:38`
(reached from `mint_transaction.rb:19`) · confirmed

`mint_era!` opens a manual `@db.exec("BEGIN")` and takes
`pg_advisory_xact_lock`. Inside it, `ensure_head_snapshot!` calls
`@db.transaction do … end`. pg 1.6.3's `PG::Connection#transaction` is a bare
`BEGIN` / `ensure COMMIT` with **no savepoint nesting** (verified against the
installed gem source, `connection.rb:308`). The inner `COMMIT` commits the
whole mint and releases the advisory lock mid-flight.

A newly-minted era's snapshot table is era-named and does not exist yet, so
the `return if table_exists?` fast path is skipped and this fires on **every
mint**. If any later step raises (e.g. a second aggregate's `convert` meeting
an unmapped value at `head_compiler.rb:265`), the `rescue`'s `ROLLBACK` runs
against no transaction — a no-op — leaving a **half-born era committed** (era
row + partition present, but `advance_era!` never ran, so the RLS write-fence
still points at the old era). The released lock also re-opens the
concurrent-mint race the code claims to close. The happy path produces
correct data, which is why live use never caught it.

### H3 — Deleting an era-migrated record resurrects it in the head view

`lib/hecksagain/adapters/driven/postgres.rb:192`; head view at
`head_compiler.rb:276` · likely (static; no live PG)

The delete branch of `append` only does
`DELETE FROM head_snapshot WHERE id=$1`. The snapshot table holds no delete
tombstone. From era ≥2 the head view is `DISTINCT ON (aggregate_id) …
ORDER BY ordinal DESC` over `matview (ancestor tail) UNION ALL head_snapshot
(current era)`, filtered `WHERE operation='save'`. For a record carried into
era N from an ancestor era, the delete removes only the (absent) snapshot
row; the matview's ancestor `save` row survives and wins the `DISTINCT ON`,
so `find`/`all`/`count` keep returning it forever. Regression from the
snapshot optimization — the older raw-journal live half included the era-N
delete row, which outranked the matview and was then filtered out correctly.
Only affects deletes of ancestor-carried records; re-saves are masked
correctly.

### H4 — Rekey SQL is invisible to the human-approval digest

`lib/hecksagain/translation/audit/approval_digest.rb` via
`lib/hecksagain/projector/exporter.rb:37` · confirmed

`edge_digest → translation_hash → translation_aggregate` serializes
renames/moves/converts/drops/retypes/**computes (with sql)** but **not
`rekeys`**. `minter.rb:49` gates the mint on rekey approval
(`approval[:edge_digest] == Audit.edge_digest(edge)`), and a rekey rewrites
every record's identity with SQL that has no mechanical verification — the
digest is its only tether. Verified: two different rekey SQLs produce the
identical digest (`335cd424537bddf0`). An approved rekey can be edited to a
different mapping and still mint under the stale approval.

### H5 — A dotted-member `compute` exempts the whole attribute from the Layer-2 gate

`lib/hecksagain/translation/audit/layer_two.rb:56` · confirmed

`compute_tops` maps `"price.cents"` to top-level key `"price"`, and both the
`expected` and `actual` sides then reject that key from the cross-execution
equivalence check. Verified: an edge computing from `price.cents` while the
migration SQL nulls `price.currency` — or drops `price` entirely — produces
**zero violations**. This is the gate whose entire purpose is to catch that.

### H6 — `limit` applied before `offset` in the in-memory query port

`lib/hecksagain/ports/query/in_memory.rb:21` · confirmed

```ruby
matched = matched.first(limit) if declared.limit
matched = matched.drop(offset) if declared.offset
```

SQL does `OFFSET` then `LIMIT`. Verified: 30 rows, `limit 10 offset 10` →
**0 rows** (SQL returns rows 11–20). Blast radius: Memory / Heki / Lambda
adapters, reference hops, and read models (which can declare both). The
agreement spec only exercises limit-alone and offset-alone, so it is
structurally blind to this.

### H7 — Reference/entity query engine ignores `offset` and dotted paths

`lib/hecksagain/runtime/query_interpreter.rb:78, 149, 261` · confirmed

- `interpret`/`reference_interpret`/`entity_rows` apply `limit` but ignore a
  declared `offset` (and `cursor`), so the fuzzer's reference oracle
  disagrees with every native engine on any offset query.
- `element_where_holds?` (`:149`) reads `element[clause.field.to_sym]`
  instead of `FieldPath.dig`, so an entity sub-list query with a dotted
  `where` (e.g. `where "price.cents" < 100`) always returns `[]`.
  `entity_rows` is the **only** engine for entity queries, so this is
  silently wrong everywhere, not merely a divergence.
- `ordered` (`:261`) reads `record[field]` instead of digging, so a dotted
  `order_by` sorts by all-`nil` (identity-tier fallback) in the reference
  engine.

### H8 — `seal_defaults` doesn't cover `one_of` closed sets

`lib/hecksagain/bluebook/dsl/aggregate_builder.rb:228` · confirmed

`seal_defaults` checks `@value_objects` only, never `closed_sets`. The exact
case named in its own comment —
`attribute :cover, one_of("covered","open"), default: "open"` — boots clean,
then refuses **every** create at dispatch with
`TypeMismatch: cover is a Cover — pass its fields as an object, not "open"`.
Sibling method `declared_value_object` (`:385`) already includes
`closed_sets`; `seal_defaults` should too.

### H9 — Meta-validator cache key omits read-model filters → stale filters served

`lib/hecksagain/bluebook/meta_validator.rb:127` · confirmed

The held-declaration cache is keyed on `SHA256(JSON(bluebook.to_h))`, but the
language deliberately holds more than `to_h` carries — `ReadModel#to_h` omits
`wheres`/`order_by`/`limit`. Verified: boot chapter A with
`where price_cents.cents == 100`, then in the same process boot an otherwise
identical chapter with `== 999`; the second boot is handed the **first**
chapter's assembled read model (filter still 100). Any same-process reload
after editing only a read-model filter (test suites, consoles, hecks_studio)
runs the stale filter. Policy→head attribution shares the same key hole.

### H10 — Stored XSS via record id (Rust web layer) — FIXED 2026-08-22

`rust/host/src/web.rs:639, 706` (also `:635, :696` lack URL-encoding) ·
likely

Every other data value routes through `esc()`, but the aggregate `id` (from
`instances_for`, i.e. user-supplied identity args, free-form unless
`pattern:`-constrained) is interpolated raw into link text, `href`
attributes, `<title>`, and `<h1>`. A creating command whose identity
component is `x"><img src=y onerror=alert(document.cookie)>` persists, then
executes for every authenticated viewer of the index or record page — stored
XSS on a public Lambda URL. The not-found branch (`:672`) and the field rows
(`:684`) correctly call `esc()`, so this is an oversight. The **Ruby**
presentation layer is not affected — it routes all dynamic content through
`Escape.html`; this is the parallel Rust reimplementation missing the same
guard.

**Fixed**: the two call sites this described (now `web.rs`'s `aggregate_index`
row-action-link builder and `record_show`'s action-link/heading, current line
numbers have shifted since this was written) were extracted into two small,
unit-tested functions — `action_link` (HTML-escapes the link text, percent-
encodes `id` via the existing `auth::urlencode` for the query-string
position — `esc()` alone isn't enough there, a raw `&` would smuggle a
second bogus query parameter) and `index_row_html` (HTML-escapes `id` for
both the path segment and the link text). The `<title>`/`<h1>` mentions
above don't independently apply to the current code: `page()`'s own title
parameter was already routed through `esc()`, confirmed by direct reading
before this fix — only the two call sites named here were ever actually
raw. The bundled URL-encoding gap noted in the parenthetical is fixed for
these same two lines as part of this change; the broader L12 finding
(URL-encoding generally, other call sites, both runtimes) is unchanged and
still open.

### H11 — Session HMAC fails open when `SESSION_SECRET` is empty

`rust/host/src/web.rs:90` · likely (latent)

```rust
fn session_secret() -> String { std::env::var("SESSION_SECRET").unwrap_or_default() }
```

`main.rs` hard-requires `DATABASE_URL`/`HECKS_DOMAIN`/`HECKS_ERA` but never
checks `SESSION_SECRET`; unset, the whole session + OAuth-`state` HMAC keys on
a publicly-known empty string, and `parse_session_cookie` then verifies
attacker-forged cookies, bypassing the `session.is_none()` gate. **Not
currently exploitable** — `deploy/embryonaut/template.yaml:500` sets it from
Secrets Manager — but the code fails **open** instead of refusing to boot,
unlike every other required var.

### H12 — Record ids containing `.` are unroutable

`lib/hecksagain/presentation/app.rb:70` · confirmed

`split_format` splits the third path segment on the first `.`, so any
identity with a dot (an email `identified_by { email.address }`, a
decimal-ish reference) creates successfully but its own detail page, JSON
representation, and index-table link all 404 — and the `.html` request
mis-negotiates to JSON (format parsed as `"1.html"`). Verified live against
banking: `reference.value=c.1` → `302 /Banking/Customer/c.1.html` →
`404 "no Customer c"`.

### H13 — `make deploy` always exits non-zero for Shared-mode domains

`bin/project_deploy` + generated `deploy/{pizzas,banking}/Makefile` ·
confirmed

The `deploy:` target ends with an unconditional `$(MAKE) mint-era`, and the
Shared-mode `mint-era` recipe is `@echo "…isn't automated yet…"; exit 1`. So
a fully successful `sam deploy` is followed by a guaranteed nonzero exit. CI
and scripted callers read every Shared-mode deploy as failed; operators learn
to ignore red deploys — the inverse of the past "check verified the wrong
thing" bug.

### H14 — Generated translation targets bypass the tunnel they stand up

`bin/project_deploy:1389` · confirmed

`make scaffold-translation` / `make translation-audit` run
`DATABASE_URL=… HECKS_SCHEMA=… ruby bin/scaffold_translation $(DOMAIN)`, on a
comment claiming the scripts resolve their DB connection from those env vars.
Grep-confirmed false: `DATABASE_URL` appears nowhere in `lib/`, and
`HECKS_SCHEMA` is read only by `rust/host/src/main.rs`. Both scripts connect
via the domain's `.world` file (`Postgres.connect_for`). So the target
deploys a real bastion and opens a real SSM tunnel to production RDS, then
scaffolds/audits the developer's **local** database and reports success.
(`mint-era` is unaffected — it passes `settings:` explicitly.)

---

## Rust parity divergence

The recorded status is "full corpus parity, 35/35 instances." That holds for
**instances** on the **three pinned fixtures**. The full corpus, built and
run during this audit (`cargo build --no-default-features --features banking`
then `bin/rust_conformance examples/banking spec/corpus/banking.json native`),
diverges:

- **6 events differ** — Rust emits `"tags"=>nil` (×4 `CardAuthorized`) and
  `"note"=>nil` (×2 `BoxOpened`) where the optional arg was omitted; Ruby
  omits the key. Root: `Json::overlay` (`rust/src/kernel/json.rs:178`) adds
  patch keys absent from the base; `rust/project/registry.rb:125` serializes
  `None` as `Json::Null`.
- **Refusals: Ruby 94 vs Rust 131** — 37 `"query steps are not generated
  yet"` placeholders (`rust/src/kernel/cli.rs:76`) interleave and shift every
  subsequent index.
- **Dispatch-order inversion** (`rust/project/registry.rb:116`) — Rust checks
  role/references before the coercion-time VO invariant/admits/pattern
  checks; Ruby's `DISPATCH_ORDER` is the reverse. Same bad input → different
  refusal per runtime (verified: wrong role + negative `daily_limit`).
- **Empty-string identity component** — accepted as the id by Rust
  (`to_id_component` returns `""`), rejected by Ruby (`Identity.of` treats
  empty as nil and falls through). Real persisted-state divergence, verified.

The pinned CI fixtures contain none of these steps, so
`spec/rust_conformance_spec.rb` stays green. The comparison logic itself is
honest (exact, order-sensitive on events/refusals); the masking is entirely
corpus selection.

**Build note:** `cargo build --features banking` **fails to compile** (E0252,
`active` defined twice) because `Cargo.toml` has `default = ["embryonaut"]`
and the domain features are mutually-exclusive but unmarked. Only
`--no-default-features --features banking` works. Latent codegen landmines in
the same file: a domain literally named `version`/`edition`/`path`/`default`
would never get its feature (`bin/project_rust:160` regex also matches
package keys); a `#{`/`#@`/control char in any bluebook description produces
an invalid Rust escape via `.inspect` and breaks the build.

---

## Medium severity

**Query engine semantics (Memory vs reference vs SQL)**
- `ports/query/in_memory.rb:33` — `ne` matches nil-held rows in memory; SQL
  `<>` excludes NULL. _confirmed_
- `ports/query/in_memory.rb:37` — `in` stringifies both sides, matching
  across types and `nil`↔`""`; diverges from `eq` and SQL. Duplicated at
  `query_interpreter.rb:216`. _confirmed_
- `query_specification/common/null_policy.rb:16` — default NULL ordering:
  memory picked SQLite's convention (nulls first ASC), opposite of Postgres's
  native default. No agreement-spec row carries a nil in an ordered field.
  _likely_
- `ports/query/in_memory.rb:74` vs `query_interpreter.rb:250` — a
  multi-numeric value object unwraps to first-numeric in one engine, whole
  hash in the other; `gt`/`lt` silently false on one side. _confirmed_
- `query_specification/field_path.rb:45` — `read` violates its "or nil, never
  raise" contract: a path through an Array raises `TypeError`, through a
  String does a substring lookup. Reachable from a console `order_by` on a
  `list_of` column (`in_memory_ordering.rb`), which surfaces a bare
  `TypeError` instead of a `WiringError`. _confirmed_

**Expression sublanguage (`bluebook/expression/`)**
- `evaluator.rb:69` — negated membership (`!names.include?(x)`) is
  inexpressible; all three spellings raise. _confirmed_
- `canonical_form.rb:39` — normalisation rewrites string-literal **contents**
  (`"a  b"→"a b"`, `"a.length"→"a.size"`), quote-blind. _confirmed_
- `resolver.rb:201` — `modulo` truncates floats and divides by
  `divisor.to_i` after a zero-check on the uncoerced divisor → raw
  `ZeroDivisionError`. _confirmed_
- `resolver.rb:212` / `evaluator.rb:72` — several raw `TypeError`s cross the
  `Vocabulary::DomainRefusal` boundary the vocabulary itself calls "a bug
  wearing a refusal's clothes." _confirmed_

**IR round-trip losses (`bluebook/ir/`)** — set as ivars, absent from
`to_h`, so a chapter reassembled from exported IR loses them silently:
- `bluebook.rb:69` — `formerly_known_as` (drives the real Postgres schema
  rename via `era_resolver.rb:15`) and chapter-level `@ports`. _confirmed /
  likely_
- `process_manager.rb:113` — `correlates_by` maps `nil → ""` on the wire.
  _confirmed_

**DSL sealing / assembly (`bluebook/dsl/`, `bluebook/assembly/`)**
- `attribute_collector.rb:34` — duplicate attribute names both survive into
  IR; nothing refuses them (duplicate command names are refused). _confirmed_
- `meta_validator/judge.rb:260` — an entity's attribute types are never
  resolved as references; an undeclared type on an entity boots clean.
  _confirmed_
- `bluebook_builder.rb:195` — entity query hops are not sealed; a `where`
  hopping through an undeclared aggregate boots clean. _confirmed_
- `marks.rb:171` / `meta_validator/shapes.rb:94` — object-literal decoders
  corrupt on an embedded `"`, and key on the pre-3.4 `=>` `Hash#inspect`
  spelling, so under Ruby ≥3.4 every object-literal default/binding decodes
  to `{}`. _confirmed / likely_
- `naming.rb:61` + `aggregate_builder.rb:88` — `plural`/`singularize` are not
  inverses for `-es`; `has_many Boxes` refuses the chapter naming a phantom
  aggregate `Boxe`. _confirmed_

**Runtime (`runtime/`)**
- `instance.rb:95` — a composite-identity creating command that doesn't
  redeclare its heads as attributes persists them as `nil`
  (`identified_by || :id` is nil-for-composite). _confirmed_
- `identity.rb:63` — `Identity.of` calls `.empty?` on each part; a non-string
  identity part (a reference-typed head) raises `NoMethodError` where a
  refusal belongs. _confirmed_
- `read_model_interpreter.rb:78` vs `sqlite/projection.rb:39` — in-process and
  SQLite read-model paths diverge on missing heads (`{}` vs `nil`), missing
  root (`NotFound` vs silent `[]`), and chained-include join scope.
  _confirmed by inspection_
- `dispatcher.rb:165` — `@reaction_depth` is a plain ivar on a thread-shared
  dispatcher (the `Caller` beside it is `Thread.current`-backed); matches the
  known Puma-concurrency bug class. _possible_

**Fuzzer / harness blind spots (`fuzzing/`)**
- `sequence_generator/outcome_tracker.rb:14` + `step_builder.rb:36` — three
  shipped framework aggregates (RoleAssignment, RoleTransition via composite
  id; the `ConsoleSettings` `Replace*` commands via `list_of` args) are
  half-unfuzzable: every acting step is refused, zero events emitted.
  Verified against Governance and ConsoleSettings. _confirmed_
- `properties.rb:61` — `saga_advances_follow_declared_handlers` passes
  vacuously: the log copies `from:`/`to:` from the handler it is then checked
  against. _confirmed_
- `replay.rb:49` — the query oracle masks refusal-shaped divergence (both
  engines share one `begin`; an entry where either raised is skipped).
  _likely_
- `bin/fuzz:139` — `shrink_arguments` never accumulates drops (rejects from
  the original hash each time), so each accepted drop reverts the previous
  ones. _confirmed (simulated)_

**Framework modeling**
- `framework/bluebook/governance.bluebook:84` — `RoleTransition` has an
  absorbing `revoked` state: identity is `(from_role, to_role)` with no
  `starts_at`, `Revoke` sets `ends_at`, nothing clears it, so a revoked pair
  can never be re-granted. Header comment wrongly claims the same shape as the
  re-grantable `RoleAssignment`. _confirmed_

**Translation (`translation/`, `ports/persistence/`)**
- `audit/layer_one.rb:24` — Layer 1 checks lifecycle values against
  `states | [default]` (targets only), not `ModelCheck.full_states`, so a
  valid `from:`-only state (minted specifically to handle old-era records) is
  flagged as a violation and blocks the mint. _confirmed_
- `ports/persistence/lineage.rb:92` — sequential in-place rename loses data on
  swap/chain renames (`{a: :b, b: :a}` on `{a:1, b:2}` → `{a:1}`), and the
  builder has no guard against a rename targeting another rename's source.
  Since this transform is Layer 2's reference, the compiled SQL agrees and the
  loss mints silently. _confirmed_

**Deploy / ops (`bin/project_deploy`)**
- `:1818` — adding Google OAuth to a live stack deadlocks `make deploy`:
  the pre-deploy `mint-era` queries outputs the upcoming deploy hasn't created
  yet. _likely_
- `:816` — RDS master passwords may contain `%`; the Ruby-side `DATABASE_URL`
  consumers (`connect_for`, Ruby WebFunction) go through libpq's URI parser,
  where a bare `%` is an invalid token. ~29% of 32-char passwords. _possible_

---

## Low severity

- `ports/projection.rb:44` — `catch_up!` enforces history consistency only
  under the exact symbol `:strict`; any other non-`:refresh` value silently
  appends onto divergent history.
- `runtime/read_model_interpreter.rb:55` — chained non-root heads are still
  declaration-order dependent one level deeper than the root-first fix
  reached.
- `runtime/era_guard.rb:29` — `Dir[…].first` inside the per-bluebook loop
  reproduces the multi-file wrong-source bug `EraCheck` already fixed; only
  reached from a spec today.
- `runtime/command_rules/arithmetic.rb:85` — `sign_of` returns `-1`
  (decrement) for any op without a sign; unreachable today, wrong default
  shape.
- `bluebook/ir/lifecycle.rb:58` — `match_transition` falls back to
  `matches.first` when no `from:` admits the state; dead code holding a wrong
  answer (zero callers).
- `runtime/value/admission.rb:14` — a multi-column `one_of` is admitted on its
  first column only; the declared row combinations are never checked. Latent.
- `bluebook/ir/value_object.rb:57` — `one_of` member values are stringified in
  `to_h` (`Integer 1 → "1"`); typed wire readers see strings.
- `bluebook/pattern_subset.rb:88` — the possessive-quantifier check doesn't
  skip character-class interiors, so `[*+]` is wrongly refused and `a{2}+` is
  wrongly admitted.
- `facade/json_door.rb:85` — `validate_command!` accepts creating-command
  names a `Handle` cannot dispatch (`klass.commands` includes creators;
  `Handle` defines only non-creators) → `NoMethodError` instead of the
  promised 404.
- `presentation/app.rb:200` — `run_query` omits `JSON::ParserError` from its
  rescue list (both command paths include it), so a malformed list-of-VO query
  line 500s instead of showing the 422 banner.
- `presentation/app.rb:106` — a record whose id equals a command/query name
  shadows its own detail page (verb match precedes record lookup).
- `presentation/record_renderer.rb:75` etc. — ids are HTML-escaped but never
  URL-encoded in `href`/`Location`; `&`, `+`, `?`, `#` in an id corrupt the
  link.
- `adapters/driven/postgres.rb:225` — `reset!` on a lineage-provisioned
  journal (FORCE RLS, no DELETE policy) silently deletes zero rows.
- `adapters/driven/sqlite.rb:86` / `d1.rb:136` — store literal `"null"` text
  for absent mirrors where Postgres stores SQL NULL; decodes the same today,
  diverges under a future `IS NULL` check.
- `bin/project` — missing the executable bit (only script that is `100644`).
- `bin/present:64` — `--port=8080` (equals form) silently ignored → serves on
  4567; `-p abc` → binds an ephemeral port, banner prints `:0`.
- `bin/evolve:48` — `option` swallows a following flag as its value and a
  missing value bypasses the declared default.
- `bin/evolve:63` — `guarded` has no rescue/ensure; `rename` writes the
  keyword row before the argument cascade, so a raise mid-cascade leaves
  `syntax.bluebook` half-renamed with no restore.
- `bin/stores:14` — a nonexistent domain path exits 0 with no output.
- `bin/project_deploy:1517` — `rename-schema` interpolates `$(OLD)`/`$(NEW)`
  unsanitized into SQL (operator-only, but against prod RDS).
- `rust/src/kernel/json.rs:108` — `f64→i64` `as` cast saturates silently where
  Ruby keeps a Bignum; large integer args diverge.
- `rust/src/kernel/expr.rs:239` — `Int + Int` uses plain `+` (debug panic /
  release wrap) where Ruby promotes to Bignum.
- `rust/host/src/web.rs:562` — `nest()`'s `.as_object_mut().unwrap()` panics
  (500) on a scalar/group path-prefix collision.
- `rust/host/src/web.rs:748` — the post-accept redirect id is
  `mutations.last().last()`, which can belong to a cascaded reaction's
  aggregate rather than the form's target.

---

## Cleared (checked, not defects)

Recorded so a later reader doesn't re-litigate them: SQL identifier quoting
and JSONB path building in the Postgres adapter; `search_path` schema
isolation; ORDER BY tiebreakers (all carry an id/ordinal tier); the
`Handle` composite-identity fix (complete — builds identity from
`identity_heads`); `JsonDoor` wiring (required, round-trips); the Ruby
presentation layer's HTML escaping (all dynamic content through `Escape.*`);
comma-bearing `contains` (now consistent across engines, pinned by
`NoteContainsPhrase`); `AppendOnly#save`'s shallow dup (write paths reassign
top-level); the `rust_conformance` comparison logic itself (honest — no
hiding sort/normalize). The masking there is corpus selection, not the diff.

---

## Suggested triage order

1. **H1, H2, H3, H4, H5** — data loss / migration integrity. H1 is the
   cheapest (add the two gate steps to the entity `DISPATCH_ORDER`); H2 is a
   one-line fix (drop the inner `@db.transaction`, or use a savepoint).
2. **S1, S2** — the two systemic root causes; fixing each retires a cluster
   of medium query bugs at once.
3. **H10, H11** — Rust web security, before that surface takes untrusted
   users beyond the current deploy.
4. **H6, H7, H8, H9, H12** — wrong-answer / broken-route bugs on live paths.
5. **H13, H14** — ops correctness (false-red deploy, wrong-DB audit).
6. Widen the three harnesses to cover their blind spots (limit+offset
   together; `false`/nil/multi-numeric-VO fields; composite-id and `list_of`
   fuzz coverage; the full Rust corpus, not just pinned fixtures) so
   regressions of the above can't pass green again.
