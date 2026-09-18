# PostgresEra's `head_view`/`head_snapshot`/`matview` now domain-qualify, closing a cross-domain storage_name collision

**Status:** Fixed, in both Ruby (`lib/hecks/ports/persistence/plugins/era/postgres_era/lineage.rb`, `.../lineage/field_cache.rb`) and Rust (`rust/host/src/journal.rs`, `rust/host/src/mint.rs`, plus their real callers in `auth.rs`, `dispatch.rs`, `web.rs`, `bin/lineage_harness.rs`) — two domains bound to `PostgresEra` against the same Postgres database, each declaring an aggregate whose own name snake_cases to the same `storage_name`, used to derive the EXACT SAME physical relations and silently share (and, worse, clobber) each other's data.

## The bug, found live

A real, private project (children-of-the-light — its own `.bluebook`/`.hecksagon`/`.world`, a real PostgresEra-backed Postgres database, already at era 12 of its own schema history) vendors a second, small bluebook chapter via `uses_embryonaut_bluebook "notes"` — a separate domain named `Notes`, bound to `PostgresEra` against the SAME database (mirrors how `examples/banking` wires `Governance`/`Identity` via `uses_framework`, a real, intended deployment shape).

The vendored `Notes` domain declares its own `aggregate "Note"`. The MAIN `ChildrenOfTheLight` domain ALSO has its own, unrelated, pre-existing `aggregate "Note"` (18+ real records, years of history). Both aggregates are named `"Note"`, and Ruby's snake-casing turns that into the same `storage_name`: `"note"`.

`Notes`' own `Note` aggregate is (and remains, since it's a small, low-traffic domain) at era 1. `ChildrenOfTheLight`'s own `Note` aggregate is at era 12, with a properly-compiled `note_head` view (a UNION of a compiled ancestor-chain matview and `note_head_snapshot_12`, holding real historical data across many eras of real journal events). Every time `Hecks.boot` runs against this multi-domain project (which happens on every normal app boot, since both domains are declared in the same registry), constructing the repository for `Notes::Note` (era 1) called `ensure_first_head!("note")` — which unconditionally `DROP VIEW`s and recreates `note_head` as the simple era-1-only form, CLOBBERING `ChildrenOfTheLight::Note`'s properly-compiled era-12 view.

Verified live: `note_head`'s view definition was manually recompiled back to the correct era-12 union form (read-only recovery, no data touched — the historical journal data was never lost, only the view definition), confirmed showing all 21 real historical notes — and then, immediately after the very next ordinary `Hecks.boot` of the same project (no code changed), `note_head` was confirmed CLOBBERED BACK to the simple era-1-only form again, via direct `psql` inspection (`\d+ note_head` showed it querying only `note_head_snapshot_1` again). A live, deterministic, reproducible, ONGOING bug — not a one-time historical artifact.

No data was ever physically commingled in the reproduction case (`note_head_snapshot_1`, the shared physical table both domains' "Note" aggregates would write NEW records into, happened to be empty at the time) — but the collision is real and active: had either domain written a NEW record while sharing era 1 with the other, both would physically land in `note_head_snapshot_1`, becoming visible (wrongly) to BOTH aggregates' queries. And the view-clobbering happens regardless of whether any write occurs at all, purely from booting.

## Root cause

`lib/hecks/ports/persistence/plugins/era/postgres_era/lineage.rb`'s naming helpers:

```ruby
def journal = "hecks_journal_#{Naming.snake(@domain)}"
...
def head_view(storage_name) = "#{storage_name}_head"
def head_snapshot(storage_name, era) = "#{storage_name}_head_snapshot_#{era}"
def matview(storage_name, era, label) = "#{storage_name}_lineage_#{era}_#{label}"
```

`journal` IS domain-qualified (`Naming.snake(@domain)` is part of the name). `head_view`, `head_snapshot`, and `matview` were qualified ONLY by `storage_name` (the aggregate's own snake_case name) — NEVER by domain. So two different domains bound to `PostgresEra` against the same database, each declaring an aggregate that snake_cases to the same name, collided on the exact same physical Postgres relations.

`lib/hecks/ports/persistence/plugins/era/postgres_era.rb`'s `PostgresEra#initialize` runs, UNCONDITIONALLY, every single boot:

```ruby
@lineage.ensure_head_snapshot!(table, @era)
@lineage.ensure_first_head!(table) if @era == 1
```

with its own comment: "belt-and-suspenders self-healing... against any boot-ordering surprise, at the cost of one CREATE TABLE IF NOT EXISTS nobody pays for twice." `ensure_first_head!` does `CREATE TABLE IF NOT EXISTS #{head_snapshot(table, 1)}` then `DROP VIEW IF EXISTS #{head_view(table)}; CREATE VIEW #{head_view(table)} AS SELECT id, state FROM #{head_snapshot(table,1)} WHERE operation='save'` — the SIMPLE era-1-only form. Constructing the repository for `Notes::Note` (era 1) on any ordinary boot therefore unconditionally rewrote `note_head`'s definition back to that simple form — whatever it held before, even a real `ChildrenOfTheLight::Note` era-12 union.

## The fix

`Lineage#head_view`/`#head_snapshot`/`#matview` now fold `Naming.snake(@domain)` into their names, the same way `#journal` already does:

```ruby
def head_view(storage_name) = qualified_name("#{storage_name}_head")
def head_snapshot(storage_name, era) = qualified_name("#{storage_name}_head_snapshot_#{era}")
def matview(storage_name, era, label) = qualified_name("#{storage_name}_lineage_#{era}_#{label}")

private

def qualified_name(suffix)
  full = "#{Naming.snake(@domain)}_#{suffix}"
  return full if full.bytesize <= POSTGRES_IDENTIFIER_LIMIT

  digest = Digest::SHA256.hexdigest(full)[0, 8]
  "#{full.byteslice(0, POSTGRES_IDENTIFIER_LIMIT - digest.bytesize - 1)}_#{digest}"
end
```

`note_head` becomes `notes_note_head` (for `Notes::Note`) and `childrenofthelight_note_head` (for `ChildrenOfTheLight::Note`) — genuinely distinct physical relations, so an ordinary boot of one domain can never again touch the other's.

### The identifier-length problem, and why a plain prefix isn't safe alone

Postgres silently TRUNCATES any identifier over 63 bytes (`NAMEDATALEN` 64, minus the trailing null) rather than refusing it. Before this fix, only `storage_name` (an aggregate's own short name) fed into these names, so the 63-byte limit was rarely close. Domain-qualifying makes it reachable: a long domain name stacked onto a long aggregate name (plus, for `matview`, an era number and a 6-character mint label) can genuinely exceed 63 bytes, and two DIFFERENT overlong names that happen to share their first 63 bytes would silently collide again, at a longer length — reintroducing the exact same class of bug this fix exists to close.

`qualified_name` handles this the same way two existing precedents in this same adapter already do — kept as readable as those precedents allow it to stay, since unlike either of them, these ARE names an operator reads and types by hand at a `psql` prompt during a live incident (this bug's own field report is a `psql`/`\d+` investigation):

- `Runtime::StorageShape.mint_label` truncates a SHA256 hex digest to 6 characters, with no attempt at readability — a mint label is never meant to be legible on its own.
- `FieldCache#field_cache` hashes its whole input (storage_name, era, field) unconditionally — also fully opaque, `hecks_backfill_progress`/catalog lookups are always driven by the same computed name, never typed by hand.

`qualified_name` degrades to a hashed, truncated form ONLY once the readable form would actually risk exceeding 63 bytes: the full `<domain>_<suffix>` string is kept verbatim when it fits, and only truncated-plus-appended-with-an-8-hex-char-SHA256-digest when it doesn't — a real (if rare) overlong pair of names stays deterministic and collision-free, while the overwhelming common case (`target_note_head`, `pizzas_order_head`, `ledger_account_head_snapshot_2`) stays exactly as legible as the field report's own live investigation needed it to be.

## A fourth, differently-shaped relation family with the identical gap: `FieldCache#field_cache`

Grepping every construction site of `head_view(`/`head_snapshot(`/`matview(` (lib, bin, spec) turned up every call going through the three helpers above — no independent reconstruction in this gem's own Ruby. But the SAME file family (`lib/hecks/ports/persistence/plugins/era/postgres_era/lineage/field_cache.rb`, mixed into `Lineage`) has its own, separate physical-relation-naming scheme for a query-acceleration cache table, ALSO storage_name-only:

```ruby
def field_cache(storage_name, era, field)
  "hecks_fc_#{Digest::SHA256.hexdigest("#{storage_name}\0#{era}\0#{field}")[0, 20]}"
end
```

Mechanically the identical bug: two domains sharing a storage_name AND a cached `where`-field name would derive the identical `hecks_fc_<hash>` table and silently share cached rows. Not one of the three named helpers, and not the collision the live field report actually hit (it never exercises a cached `where` field), but found by the same required call-site sweep and fixed alongside them — `@domain` is now part of the hashed input:

```ruby
def field_cache(storage_name, era, field)
  "hecks_fc_#{Digest::SHA256.hexdigest("#{@domain}\0#{storage_name}\0#{era}\0#{field}")[0, 20]}"
end
```

Already fully hashed either way, so this costs nothing readability could lose.

## The Rust side: `rust/host` independently reimplements this same naming scheme, twice

Grepping `rust/host/src` for the same shapes (`_head`, `_head_snapshot_`, `_lineage_`) found this naming scheme reconstructed independently, NOT shared with Ruby's own computation, in **two separate places**:

1. **`rust/host/src/journal.rs`** — its own `head_view`/`head_snapshot_table` functions, storage_name-only. Its two PUBLIC generic read functions, `read_lineage_head_all`/`read_lineage_head_by_id` (the functions `rust_host_lineage_conformance_spec.rb` exists to prove agree with Ruby's own writes), didn't even take a `domain` parameter before this fix.
2. **`rust/host/src/mint.rs`** — a FULLY SEPARATE, independently duplicated copy of the whole naming family (`journal_table`, `sequence`, `partition`, `head_snapshot`, `matview`, `head_view`), deliberately not sharing code with `journal.rs`'s own copies (its own comment explains why: `journal_table`/`sequence`/`partition` already agreed with Ruby's `journal`/`sequence`/`partition`; `head_snapshot`/`matview`/`head_view` did not, until this fix).

This is not optional to leave alone: `rust/host` is a real, deployed alternate dispatcher for PostgresEra-bound domains (ADR 0036's own subject — "`rust/host` dispatching against the same PostgresEra-bound tables from a separate OS process"), and `spec/rust_host_lineage_conformance_spec.rb` already proves Ruby's and Rust's writes land in, and reads come from, the exact same physical relations. Fixing only the Ruby side would have made that claim FALSE going forward — Ruby would compute a domain-qualified name while Rust kept computing the old, unqualified one, a genuine NEW Ruby/Rust physical-naming disagreement, exactly the class of bug ADR 0036's own Blocker 1 was about.

Both Rust copies now compute names through one shared `qualified_name(domain, suffix)` (`journal.rs`, `pub(crate)`) — the SAME algorithm (63-byte limit, 8-hex-char SHA256 truncation suffix) as Ruby's own `Lineage#qualified_name`, `mint.rs` delegating to it rather than reimplementing it a third time, matching the precedent its own `storage_shape_snake` already set for `snake`. `domain` is now threaded through `read_lineage_head_all`/`read_lineage_head_by_id` and their four real callers: `auth.rs` (`member_row_by_email`, `member_rows`, `session_for_member_by_identity` — reading `domain_ir.get("name")`, the same extraction `ir.rs`/`web.rs` already use elsewhere) and `rust/host/src/bin/lineage_harness.rs` (`read_all`/`read_by_id`, reading `config.domain` — already present at every call site as the CLI's own `<domain>` positional argument, unused until now).

Two more independent reconstructions of the SAME `{storage_name}_head_snapshot_{era}` shape turned up in `dispatch.rs` and `web.rs` — both `#[cfg(test)]`-only fixture helpers (`provision_lineage`) that hand-provision a scratch snapshot table before exercising the real `handle`/dispatch path, now also routed through `qualified_name`.

**Verified this is a real, closed loop, not just a parallel assertion**: `spec/rust_host_lineage_conformance_spec.rb`'s own "mints the same edge independently in Ruby and in Rust and produces byte-identical account_head views" example — the ONE place in this codebase where Ruby and Rust each independently mint the SAME edge against separate scratch databases and diff their final head views byte-for-byte — passed after this fix (`5 examples, 0 failures`, see Verification below), proving Ruby's and Rust's newly-domain-qualified names genuinely agree, not merely that each was independently updated.

## Why `uses_framework` reproduces this identically (confirmed live, not assumed)

Unlike ADR 0058's own bug (a single-file-directory fallback specifically excluded `Framework.members` names but not `uses_embryonaut_bluebook`-vendored ones), THIS bug has no such asymmetry: `lineage.rb`'s naming helpers never look at how a chapter was attached — `uses_framework` and `uses_embryonaut_bluebook` both just add a bluebook to the same registry, and `PostgresEra#initialize` resolves `@domain` from the aggregate's own owning chapter name either way. Confirmed directly, not just reasoned about: `spec/runtime/postgres_era_storage_name_collision_spec.rb`'s "uses_framework" example wires a domain (`Custodian`) whose own aggregate is named `"RoleAssignment"` — the same name as one of `Governance`'s own two real aggregates — via `uses_framework "Governance"`, and reproduces the identical collision (confirmed RED pre-fix: `Governance::RoleAssignment.count` read back `1` after only `Custodian::RoleAssignment` was written).

## Existing deployments: NOT retroactively migrated, by design, left as a named follow-up

This fix makes NEW/future table names domain-qualified going forward, self-healing via the same `CREATE TABLE IF NOT EXISTS` idempotency this adapter already leans on everywhere — but it does **not** migrate an already-shipped project's EXISTING physical tables to their new, domain-qualified names. A real deployment (children-of-the-light) already has real data sitting under the OLD, non-domain-qualified names (`note_head`, `note_head_snapshot_1`, etc., across both its own `Note` aggregate's real era-12 history and `Notes`' own). After this fix ships, that deployment's next boot would compute NEW names (`childrenofthelight_note_head`, `notes_note_head`) that do not exist yet, and `ensure_first_head!`/`ensure_head_snapshot!`'s own idempotent `CREATE TABLE IF NOT EXISTS`/`CREATE OR REPLACE VIEW` would happily create them EMPTY — which would look like boot succeeding while actually starting both domains' aggregates from a blank slate, silently orphaning every existing row under the old names.

This is exactly the same category of gap PR #722 (ADR 0058) left named rather than silently smoothed over for its own sibling bug, and is handled the same way here: **out of scope for this PR**, to be handled separately, by hand, against the real database — most likely by rekeying (`ALTER TABLE ... RENAME TO`, `ALTER VIEW ... RENAME TO`, `ALTER MATERIALIZED VIEW ... RENAME TO`) each of `Notes`' and `ChildrenOfTheLight`'s own existing physical relations to their new, domain-qualified names before that deployment's next boot, verified against `Lineage#qualified_name`'s own real output for its own real domain/storage_name/era/label combinations. **Not done here, not implied to be automatic — named explicitly as the follow-up it is.**

## Verification

- **Reproduced directly against a real, disposable local Postgres database**, entirely inside this repo (`spec/runtime/postgres_era_storage_name_collision_spec.rb`, `:io`, four examples):
  1. `uses_embryonaut_bluebook` (the live report's own attachment mechanism): two fresh (era 1) domains, `Target`/`Notes`, both declaring an aggregate named `"Note"`. Dispatched real commands through each domain's own real command; confirmed (post-fix) each domain's own query sees only its own write, and confirmed via `information_schema`/`pg_views`/`pg_matviews` that the two domains occupy genuinely distinct physical relations (`target_note_head_snapshot_1`/`notes_note_head_snapshot_1`, `target_note_head`/`notes_note_head`).
  2. The same fixture booted a second time, confirming neither domain's own data is lost across a re-boot.
  3. `uses_framework`: a domain (`Custodian`) whose own aggregate shares a name (`"RoleAssignment"`) with one of `Governance`'s own two real framework-member aggregates — confirmed the identical collision reproduces (repository-level, no command dispatch/role-grant machinery needed, since a repository is built the same way regardless of whether anything ever authorizes a command against it).
  4. **The actual reported damage, reproduced end to end**: minted `Target::Note` through a REAL era-2 translation edge (a trivial `rename`, mirroring `lineage_spec.rb`'s own minimal V1/V2 shape) with one real, translated historical record — confirmed via direct SQL that `target_note_head` was genuinely the compiled union view (`SELECT ... FROM target_note_lineage_2_<label> ... UNION ALL ...`), not a plain snapshot read, BEFORE `Notes` ever boots at all. Then booted the REAL multi-bluebook project directory (`Hecks.boot`, both `Target` at era 2 and the vendored `Notes` at a fresh era 1, in ONE registry) — the exact moment the live bug happened — and confirmed Target's own real, translated data is STILL correctly visible afterward, Notes' own fresh self-mint landed in its own physical relations, and neither domain's own view definition mentions the other's.
- **Confirmed RED against the pre-fix code**: reverted `lineage.rb`/`field_cache.rb` to their pre-fix content (`git checkout`, patch saved and reapplied afterward), reran the new spec. Three of the four examples failed at exactly the expected site: example 1 read `["notes-owns-this", "target-owns-this"]` where it expected only `["target-owns-this"]` (real, live cross-domain data leakage); example 3 read `Governance::RoleAssignment.count == 1` where it expected `0`; example 4 raised `PG::UndefinedTable: relation "target_note_head" does not exist` (the pre-fix code never derived a domain-qualified name at all, so the post-fix assertion's own table name didn't exist under the OLD code — the sharpest possible confirmation the fix, not a coincidence, produces these names). Restored the fix, reran: `4 examples, 0 failures`.
- **Full related Ruby suite green, for real**, `CI=1 bundle exec rspec --tag io`:
  - `spec/adapters/driven/postgres_era_spec.rb`, `spec/adapters/driven/postgres_era/lineage_spec.rb`, `spec/fuzzing/era_boundary_spec.rb` together: `68 examples, 0 failures` (every literal pre-fix table-name assertion in these three files — traced by hand to each example's own real domain — updated to its new, domain-qualified form: `pizzas_order_head_snapshot_1`, `refs_ticket_head`, `ledger_account_head`/`ledger_acct_head_snapshot_*`, `pricing_quote_lineage_2_*`, `roster_person_lineage_2_*`, `era_boundary_fixture_widget_head_snapshot_1`, etc.).
  - `spec/rust_host_lineage_conformance_spec.rb`: `5 examples, 0 failures`, including the byte-identical Ruby/Rust mint-diff example (the strongest available confirmation that Ruby and Rust now agree on physical naming, not just that each was updated).
  - `spec/runtime/postgres_era_storage_name_collision_spec.rb` (this fix's own new coverage): `4 examples, 0 failures`.
- **`rust/host`'s own real suite, for real**, after building the real `rust/dist/banking.wasm`/`checkout_fixture.wasm` fixtures (`bundle exec bin/project_wasm examples/banking`, `bundle exec bin/project_wasm spec/fixtures/rust_host/checkout_fixture`, then restoring the tracked `rust/src/generated`/`rust/Cargo.toml` side effects, matching `ci-rust-host.yml`'s own documented procedure) and a genuine `rustc 1.98.0` toolchain (this machine's ambient Homebrew `cargo` is 1.94.0, below what `rust-toolchain.toml` pins — used `~/.cargo/bin/cargo`, the rustup shim, throughout): `cargo build` clean (only two pre-existing, unrelated `dead_code` warnings); `cargo test` — `137 passed` (`bootstrap`), `5 passed` (`lineage_harness`), `43 passed` (`mint_harness`), `0 failed` across all three binaries, including every test this fix touched (`journal::lineage_tests::*`, `auth::tests::member_lookups_query_the_real_member_head_shape`, `auth::tests::append_member_state_writes_the_journal_and_advances_the_head_snapshot`, `mint::tests::rust_mints_both_eras_itself_writes_and_reads_back_the_translated_data`, `mint::tests::audit_before_mint_passes_a_true_edge_and_refuses_a_lying_one`, `dispatch::tests::accepts_and_persists_a_first_command` and its siblings).
- **`bundle exec rubocop`** on every changed Ruby file (`lineage.rb`, `field_cache.rb`, the five updated specs, the new spec): `no offenses detected` across two separate runs (one `Lint/UselessConstantScoping` offense from an initial draft — `POSTGRES_IDENTIFIER_LIMIT` declared under `private`, which Ruby constants are never actually scoped by — fixed by moving the constant above `private`; five `RSpec`/`Layout` offenses in the new spec, four autocorrected, one `RSpec/ExampleLength` disabled-next with a named reason, matching this file's own established convention for its genuinely-inseparable end-to-end examples).
- **The real `git push` gate** (`.githooks/pre-push` — full parallel suite, fuzzer, rubocop, doc coverage, model checks, ~run for real) — see the PR/commit for its actual pass/fail output. Note: this local hook deliberately excludes Rust-toolchain-dependent specs (its own header: "Rust was restarted... very much alive... CI runs them instead") — `rust_host_lineage_conformance_spec.rb` and `cargo test` were run manually above, for real, precisely because the local gate does not cover them.
