// THE REHYDRATE-AND-REPLAY JOURNAL — flat and DELIBERATELY non-era-
// aware, domain-agnostic: one table for the WHOLE domain's command
// history, not one per aggregate. This journal alone has no era/lineage
// concept (by design, not by gap — see the generic lineage read/write
// functions further down this file for the part of this crate that
// does), and rust/host has no type information about aggregates/
// commands (that knowledge lives only inside the compiled `.wasm`
// module, which this crate treats as opaque) — so filtering "which
// prior commands matter for this one" isn't something rust/host can
// safely do on its own. Replaying the FULL log on every invocation is
// the simplest correct answer for a company-internal tool with modest
// total event volume; see docs/implemented/decisions/0018-rehydrate-replay-lambda-
// host.md for the full tradeoff.
//
// Determinism is what makes this safe to persist selectively: every
// prior journal row was, by construction, a command that succeeded the
// first time it was dispatched — replaying the exact same steps against
// the exact same (empty-start) kernel must produce the exact same
// result again. So the ONLY step in a full replay that can legitimately
// end up in `refusals` is the newest one, appended last. That's the
// entire correctness argument `append_if_accepted` below leans on.

use sha2::{Digest, Sha256};
use tokio_postgres::{Client, GenericClient};

pub async fn ensure_schema(client: &Client) -> anyhow::Result<()> {
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_lambda_journal (
                ordinal     BIGSERIAL PRIMARY KEY,
                verb        TEXT NOT NULL,
                args        JSONB NOT NULL,
                recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )",
        )
        .await?;
    // A SINGLE-ROW cache of the kernel's own last "instances" output —
    // `boolean PRIMARY KEY DEFAULT true CHECK (id)` is the standard
    // Postgres one-row-table trick (only `true` can ever satisfy both
    // the PK and the CHECK, so a second row is structurally impossible).
    // See `load_snapshot`/`save_snapshot` below for what this is for.
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_lambda_snapshot (
                id      boolean PRIMARY KEY DEFAULT true CHECK (id),
                ordinal bigint  NOT NULL,
                seed    jsonb   NOT NULL
            )",
        )
        .await?;
    // ADDITIVE, on an existing table a live domain may already have a
    // row in — `sagas_backfilled` is the one-time latch `load_snapshot`'s
    // own doc comment explains; `DEFAULT false` on the ALTER means every
    // pre-existing row (a domain with real history from before saga
    // durability shipped) reads `false` exactly once, the correct
    // "not backfilled yet" answer, without any separate migration step.
    client
        .batch_execute(
            "ALTER TABLE hecks_lambda_snapshot ADD COLUMN IF NOT EXISTS sagas_backfilled boolean NOT NULL DEFAULT false",
        )
        .await?;
    // LIVE PROCESS-MANAGER STATE — one row per in-flight saga instance,
    // not a single-row cache like hecks_lambda_snapshot above: sagas are
    // numerous, long-lived, and mostly independent (many concurrent,
    // unrelated correlations), so a shared blob would force every
    // saga-touching command to read-modify-write the entire live saga
    // population. No `ordinal` column — this table isn't replayed like
    // the journal or cached-against-an-ordinal like the snapshot; it's
    // live, always-overwritten-or-deleted-in-place state, correct by
    // virtue of always being written inside the same advisory-locked
    // transaction as everything else in `dispatch::handle` — see
    // dispatch.rs's own comment on why that's load-bearing, not
    // incidental.
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_lambda_sagas (
                process_manager TEXT  NOT NULL,
                correlation     TEXT  NOT NULL,
                state           TEXT  NOT NULL,
                memory          JSONB NOT NULL,
                PRIMARY KEY (process_manager, correlation)
            )",
        )
        .await?;
    // A CROSS-DOMAIN DELIVERY THAT NEVER GOT THROUGH, durably — see
    // `record_dead_letter`'s own header for the full argument (this
    // table exists so that fact survives past the one Lambda invocation
    // that hit it, not just this crate's own stdout/CloudWatch log
    // line). Flat and domain-agnostic, same reasoning as `hecks_lambda_
    // journal` above: one table for whatever this deployment's own
    // schema (HECKS_SCHEMA, main.rs) isolates, not one per source
    // domain — there is only ever one source domain per deployed
    // Lambda anyway.
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_cross_domain_dead_letters (
                id            BIGSERIAL PRIMARY KEY,
                policy        TEXT NOT NULL,
                target_domain TEXT NOT NULL,
                target_verb   TEXT NOT NULL,
                payload       JSONB NOT NULL,
                error         TEXT NOT NULL,
                attempts      INT NOT NULL,
                recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
            )",
        )
        .await?;
    Ok(())
}

/// A cross-domain reaction that exhausted every retry `lambda_client::
/// deliver_with_retry` attempted and still never reached its target —
/// recorded durably, in the SAME Postgres this crate already depends on
/// regardless of deploy target (not an AWS-native SQS/DLQ — the retry/
/// dead-letter mechanism this function is half of lives entirely above
/// the `LambdaInvoker` trait boundary, so it applies the same way to any
/// implementer, Amazon or otherwise; see `lambda_client.rs`'s own
/// header). Written OUTSIDE the main command's own transaction —
/// `dispatch::handle` only ever reaches this AFTER that transaction has
/// already committed (the same "best-effort, after the fact, never
/// rolls back the local write" rule cross-domain delivery already holds
/// itself to) — so a dead letter failing to record is its own concern,
/// never a reason to undo an already-durable local command.
pub async fn record_dead_letter<C: GenericClient>(
    client: &C,
    policy: &str,
    target_domain: &str,
    target_verb: &str,
    payload: &serde_json::Value,
    error: &str,
    attempts: i32,
) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_cross_domain_dead_letters \
             (policy, target_domain, target_verb, payload, error, attempts) \
             VALUES ($1, $2, $3, $4, $5, $6)",
            &[&policy, &target_domain, &target_verb, payload, &error, &attempts],
        )
        .await?;
    Ok(())
}

/// Every command ever successfully dispatched, in order, as `{"verb",
/// "args"}` objects — the exact shape a `{"steps": [...]}` entry needs.
///
/// Generic over `GenericClient` (implemented by both `Client` and
/// `Transaction<'_>`) so `dispatch::handle` can run this — and `append`
/// below — inside the SAME transaction that holds the advisory lock
/// serializing concurrent invocations. See dispatch.rs's own comment
/// for why that matters.
pub async fn load_steps<C: GenericClient>(client: &C) -> anyhow::Result<Vec<serde_json::Value>> {
    let rows = client
        .query(
            "SELECT verb, args FROM hecks_lambda_journal ORDER BY ordinal",
            &[],
        )
        .await?;

    Ok(rows
        .iter()
        .map(|row| {
            let verb: String = row.get(0);
            let args: serde_json::Value = row.get(1);
            serde_json::json!({ "verb": verb, "args": args })
        })
        .collect())
}

/// Only the steps AFTER `ordinal` — what still needs replaying on top
/// of a snapshot that was taken as of that ordinal. Normally empty:
/// `save_snapshot` runs in the SAME transaction as `append`, so the
/// snapshot is current after every single successful command. Non-empty
/// only if a snapshot write was ever skipped (there's no code path that
/// does today) — "replay the tail since the last known-good seed" is
/// the correct, self-healing fallback either way, not an error.
pub async fn load_steps_after<C: GenericClient>(client: &C, ordinal: i64) -> anyhow::Result<Vec<serde_json::Value>> {
    let rows = client
        .query(
            "SELECT verb, args FROM hecks_lambda_journal WHERE ordinal > $1 ORDER BY ordinal",
            &[&ordinal],
        )
        .await?;

    Ok(rows
        .iter()
        .map(|row| {
            let verb: String = row.get(0);
            let args: serde_json::Value = row.get(1);
            serde_json::json!({ "verb": verb, "args": args })
        })
        .collect())
}

pub struct Snapshot {
    pub ordinal: i64,
    pub seed: serde_json::Value,
    pub sagas_backfilled: bool,
}

/// The kernel's own "instances" output as of `ordinal` — what a fresh
/// `Store::from_seed` (rust/src/kernel, adf38fd's follow-up) needs to
/// stand in for a full replay. `None` before the first command this
/// journal has ever accepted (nothing to seed from yet — `dispatch::
/// handle` falls back to `Store::new()`/an empty seed, exactly today's
/// behavior for a brand-new domain).
///
/// `sagas_backfilled` is a ONE-TIME LATCH, not a live fact — it answers
/// "has this domain's snapshot row ever been written by code that knows
/// about `hecks_lambda_sagas`," never "does `hecks_lambda_sagas` happen
/// to be empty right now." That distinction matters: a saga table being
/// empty is the ORDINARY case (most invocations have no saga in flight
/// — `end_saga` deletes on completion), so triggering a full replay off
/// bare emptiness would force one on every such invocation forever, not
/// once. The latch is what makes this a genuine one-time backfill:
/// `save_snapshot` sets it `true` on every write from now on, so the
/// very first write after this column exists is the only one that ever
/// finds it `false`.
pub async fn load_snapshot<C: GenericClient>(client: &C) -> anyhow::Result<Option<Snapshot>> {
    let rows = client
        .query("SELECT ordinal, seed, sagas_backfilled FROM hecks_lambda_snapshot", &[])
        .await?;
    Ok(rows.first().map(|row| Snapshot { ordinal: row.get(0), seed: row.get(1), sagas_backfilled: row.get(2) }))
}

/// Returns the new row's own ordinal — `save_snapshot` needs it to
/// record exactly which command the snapshot it's about to write
/// reflects.
pub async fn append<C: GenericClient>(
    client: &C,
    verb: &str,
    args: &serde_json::Value,
) -> anyhow::Result<i64> {
    let row = client
        .query_one(
            "INSERT INTO hecks_lambda_journal (verb, args) VALUES ($1, $2) RETURNING ordinal",
            &[&verb, &args],
        )
        .await?;
    Ok(row.get(0))
}

/// Upserts the one-row cache — `ordinal` is the journal row this
/// `seed` already reflects (i.e. replaying nothing after it, against
/// this seed, reproduces the current world). Called in the SAME
/// transaction as the `append` whose ordinal it's given, right after a
/// command is accepted — see dispatch.rs.
///
/// ALWAYS writes `sagas_backfilled = true` — unconditionally, not
/// conditionally on whether IT was the backfilling write. Once this
/// column exists at all, every future snapshot write was produced by
/// saga-aware code, so every future READ of this row should find the
/// latch already set; only a row written before this column existed
/// (or never written at all) reads `false`.
pub async fn save_snapshot<C: GenericClient>(client: &C, ordinal: i64, seed: &serde_json::Value) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_lambda_snapshot (id, ordinal, seed, sagas_backfilled) VALUES (true, $1, $2, true) \
             ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, seed = EXCLUDED.seed, sagas_backfilled = true",
            &[&ordinal, seed],
        )
        .await?;
    Ok(())
}

/// One live saga/process-manager instance, as `hecks_lambda_sagas`
/// holds it.
pub struct SagaRow {
    pub process_manager: String,
    pub correlation: String,
    pub state: String,
    pub memory: serde_json::Value,
}

/// Every live saga instance for this domain — read once per invocation,
/// before `cli::run`, and used to seed the kernel's in-memory `sagas`
/// map. A full-table read, not windowed: only currently in-flight
/// instances have rows at all (`end_saga` deletes on completion), so
/// there's no meaningful "since ordinal X" the way `load_steps_after`
/// has for the flat journal.
pub async fn load_sagas<C: GenericClient>(client: &C) -> anyhow::Result<Vec<SagaRow>> {
    let rows = client
        .query(
            "SELECT process_manager, correlation, state, memory FROM hecks_lambda_sagas",
            &[],
        )
        .await?;
    Ok(rows
        .into_iter()
        .map(|row| SagaRow {
            process_manager: row.get(0),
            correlation: row.get(1),
            state: row.get(2),
            memory: row.get(3),
        })
        .collect())
}

/// Upserts one live saga instance's current state — called once per
/// `(process_manager, correlation)` key present in the kernel's
/// post-run `saga_snapshot`, in the SAME transaction as `append`/
/// `save_snapshot`. Must run against `&txn`, never a post-commit
/// connection the way `record_dead_letter` deliberately does — a saga
/// checkpoint that committed independently of the triggering command's
/// own journal append would be worse than not having this table at
/// all (see dispatch.rs's own comment on why).
pub async fn save_saga<C: GenericClient>(
    client: &C,
    process_manager: &str,
    correlation: &str,
    state: &str,
    memory: &serde_json::Value,
) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_lambda_sagas (process_manager, correlation, state, memory) \
             VALUES ($1, $2, $3, $4) \
             ON CONFLICT (process_manager, correlation) DO UPDATE \
             SET state = EXCLUDED.state, memory = EXCLUDED.memory",
            &[&process_manager, &correlation, &state, memory],
        )
        .await?;
    Ok(())
}

/// Removes one saga instance that ended — mirrors `sagas.remove(&key)`
/// in `orchestrate.rs`'s own `end_saga` exactly.
pub async fn delete_saga<C: GenericClient>(
    client: &C,
    process_manager: &str,
    correlation: &str,
) -> anyhow::Result<()> {
    client
        .execute(
            "DELETE FROM hecks_lambda_sagas WHERE process_manager = $1 AND correlation = $2",
            &[&process_manager, &correlation],
        )
        .await?;
    Ok(())
}

// ── THE RUBY-SHAPED LINEAGE JOURNAL — an ADDITIONAL write path, not a
// replacement for the flat log above. `hecks_lambda_journal` remains
// the sole source `dispatch::handle` rehydrates from; the functions
// below write each accepted command's own mutations (the kernel's new
// "mutations" output field, adf38fd) into the SAME per-aggregate,
// era-partitioned schema Ruby's own PostgresEra adapter uses
// (lib/hecks/adapters/driven/postgres_era.rb + postgres_era/lineage.rb) —
// same table names, same era fence — so the two runtimes can point at
// the SAME database and a human/Ruby tooling reading it sees this
// runtime's writes the same way Ruby's own `head_view` already
// presents them.
//
// rust/host never PROVISIONS this schema — no CREATE TABLE, no era
// mint, no RLS policy. That's Ruby's LineageManager's job alone (it
// needs the bluebook parser and translation-rule DSL this crate
// deliberately doesn't have — ADR 0007). `current_era` below is a
// boot-time READ, refusing cleanly if Ruby hasn't provisioned the
// configured domain yet OR if this checkout's own era has since been
// superseded by a later mint — a real, Rust-side staleness check, but
// one that only ever needs to run ONCE per process lifetime, at boot.
// A write for a stale era ALSO refuses through Postgres's own RLS row
// policy (`hecks_current_era`, postgres/lineage/mint_transaction.rb) —
// that's not redundant with the boot check, it's the second layer that
// still matters for a process that was current when it booted and got
// stranded mid-lifetime by a mint that happened after (a live Lambda
// execution environment can outlive the deploy that supersedes it).
// Neither layer duplicates the other's actual logic: the boot check
// reads `hecks_eras` once and compares an ordinal; the RLS policy is a
// row-level Postgres CHECK this crate never evaluates itself.

/// Which domain journal and era this deployed binary writes as —
/// operational facts, like Ruby's own `settings[:domain]`/`settings[:era]`,
/// never computed or embedded by this crate itself (main.rs reads them
/// from `HECKS_DOMAIN`/`HECKS_ERA`).
pub struct LineageConfig {
    pub domain: String,
    pub era: i32,
}

/// `Naming.snake` (lib/hecks/naming.rb:30-35), ported verbatim — a
/// pure syntactic transform (PascalCase/camelCase -> snake_case) with
/// no semantic judgment, unlike shape-hashing or translation-rule
/// compilation, so duplicating it here (rather than inventing a
/// different convention Ruby would need to match) is safe. Two passes,
/// matching the two `gsub`s exactly:
///   1. `([A-Z]+)([A-Z][a-z])` — an acronym running into a word
///      ("HTTPServer" -> "HTTP_Server").
///   2. `([a-z\d])([A-Z])` — an ordinary word boundary
///      ("SafeDeposit" -> "Safe_Deposit").
pub fn snake(name: &str) -> String {
    word_boundary(&acronym_boundary(name)).to_ascii_lowercase()
}

fn acronym_boundary(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_uppercase() {
            let mut j = i;
            while j < chars.len() && chars[j].is_ascii_uppercase() {
                j += 1;
            }
            let run_len = j - i;
            if run_len >= 2 && j < chars.len() && chars[j].is_ascii_lowercase() {
                out.extend(&chars[i..j - 1]);
                out.push('_');
                out.push(chars[j - 1]);
                i = j;
                continue;
            }
            out.extend(&chars[i..j]);
            i = j;
            continue;
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn word_boundary(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::new();
    for (idx, &c) in chars.iter().enumerate() {
        if idx > 0 && c.is_ascii_uppercase() {
            let prev = chars[idx - 1];
            if prev.is_ascii_lowercase() || prev.is_ascii_digit() {
                out.push('_');
            }
        }
        out.push(c);
    }
    out
}

/// `aggregate.storage_name` (ir/aggregate.rb:96: `Naming.snake(@name)`)
/// — `@name` is the aggregate's own short Pascal name WITHIN its
/// bluebook, never domain-qualified, so this demodulizes a
/// `MutationRecord.aggregate` value like `"Banking::Customer"` (the
/// kernel's own qualified form, orchestrate.rs's `rsplit("::")`
/// convention) down to `"Customer"` before snaking it.
fn storage_name(qualified_aggregate: &str) -> String {
    let short = qualified_aggregate.rsplit("::").next().unwrap_or(qualified_aggregate);
    snake(short)
}

/// `PG::Connection.quote_ident`'s own rule: wrap in double quotes,
/// double any embedded double quote. Every identifier this module
/// builds from a domain/aggregate NAME (never from caller-controlled
/// data) goes through this before reaching a `CREATE`/table-name
/// position — table names can't be bound as query parameters.
pub(crate) fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn journal_table(domain: &str) -> String {
    format!("hecks_journal_{}", snake(domain))
}

fn head_snapshot_table(qualified_aggregate: &str, era: i32) -> String {
    format!("{}_head_snapshot_{}", storage_name(qualified_aggregate), era)
}

/// The boot-time gate — but "does this ordinal have a row" was never
/// the real question, and used to be all this asked. `hecks_eras` is
/// append-only (a superseded era's row never gets deleted — era history
/// is a fact, same as everything else this system holds), so a bare
/// existence check would happily pass a STALE checkout: HECKS_ERA
/// pointing at an ordinal that once was current but has since been
/// superseded by a later mint. That stale checkout would go on writing
/// into `hecks_lambda_journal` (this file's own top header: flat,
/// domain-wide, NO era column at all) completely unrefused for any
/// command that doesn't happen to touch a lineage-capable aggregate —
/// Ruby's own RLS fence (`hecks_current_era`, mint_transaction.rb) only
/// guards the era-partitioned lineage tables below, not this one. This
/// answers the question Ruby's own `EraStore#current_era` answers
/// instead (postgres/lineage/era_store.rb: `held.last[:ordinal]`, eras
/// read ordinal-ascending) — ordinals are minted strictly increasing
/// (`minter.rb`: `ordinal = latest[:ordinal] + 1`, never reused, never
/// decremented), so the highest one on file for a domain IS the live
/// one, and `MAX`/`ORDER BY ... LIMIT 1` is exactly that fact, not an
/// approximation of it. `None` means `hecks_eras` has never heard of
/// this domain at all — nothing minted yet.
pub async fn current_era(client: &Client, domain: &str) -> anyhow::Result<Option<i32>> {
    let rows = client
        .query(
            "SELECT ordinal FROM hecks_eras WHERE domain = $1 ORDER BY ordinal DESC LIMIT 1",
            &[&domain],
        )
        .await?;
    Ok(rows.first().map(|row| row.get(0)))
}

/// One `MutationRecord` (kernel/mod.rs) as the kernel's own JSON
/// output shapes it — parsed generically since rust/host never links
/// the kernel crate (it only ever sees JSON, ADR 0012).
pub struct Mutation<'a> {
    pub aggregate: &'a str,
    pub id: &'a str,
    pub operation: &'a str,
    pub state: &'a serde_json::Value,
}

/// The SAME two-step append `PostgresEra#append` (postgres_era.rb:176-201)
/// does for a live Ruby write: journal INSERT first (era-tagged,
/// `RETURNING ordinal`), then a head-snapshot upsert guarded by
/// `WHERE ordinal < EXCLUDED.ordinal` (never regress a snapshot from
/// a stale/reordered write) — same transaction, same ACID atomicity
/// argument. `operation` is always `"save"` today (see mod.rs's own
/// `MutationRecord` doc — no generated dispatch path calls delete);
/// this only handles that case, matching current real behavior.
pub async fn append_lineage_mutation<C: GenericClient>(
    client: &C,
    config: &LineageConfig,
    mutation: &Mutation<'_>,
) -> anyhow::Result<()> {
    if mutation.operation != "save" {
        anyhow::bail!(
            "hecks_journal_{}: unsupported operation {:?} — only \"save\" is generated today",
            snake(&config.domain),
            mutation.operation
        );
    }

    let journal = journal_table(&config.domain);
    let snapshot = head_snapshot_table(mutation.aggregate, config.era);
    let storage = storage_name(mutation.aggregate);

    let row = client
        .query_one(
            &format!(
                "INSERT INTO {} (era, aggregate, aggregate_id, operation, state) \
                 VALUES ($1, $2, $3, $4, $5) RETURNING ordinal",
                quote_ident(&journal)
            ),
            &[&config.era, &storage, &mutation.id, &mutation.operation, &mutation.state],
        )
        .await?;
    let ordinal: i64 = row.get(0);

    client
        .execute(
            &format!(
                "INSERT INTO {snap} (id, ordinal, state) VALUES ($1, $2, $3) \
                 ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, state = EXCLUDED.state \
                 WHERE {snap}.ordinal < EXCLUDED.ordinal",
                snap = quote_ident(&snapshot)
            ),
            &[&mutation.id, &ordinal, &mutation.state],
        )
        .await?;

    Ok(())
}

// ── GENERIC LINEAGE READS — the READ half of what `append_lineage_
// mutation` above already is for writes: one function, any lineage-
// capable aggregate, not a hand-typed one per aggregate. Reads the SAME
// `<storage>_head` VIEW Ruby's own `Adapters::Postgres#all`/`#find`
// already read (`lineage.head_view(table)`, postgres/lineage/head_
// compiler.rb) — a plain view Ruby's LineageManager compiles at mint
// time, era-union and every rename/move/convert/drop already folded in
// via SQL (`hecks_tr_*` helpers, head_compiler.rb's own `compile_rules`)
// BEFORE this crate ever sees a row. That is what makes this safe and
// simple: neither function below needs to know a single thing about
// eras, translations, or shape drift — reading the head view IS reading
// "the current, already-translated truth," by construction, the exact
// same guarantee auth.rs's own `member_row_by_email`/`member_rows`
// already leaned on for the one aggregate (`Embryonaut::Member`) that
// needed it BEFORE this was generic. Those two functions are thin
// wrappers over these now (auth.rs) — proof this generalizes, not just
// a parallel implementation.
//
// DELIBERATELY NOT WIRED INTO `dispatch::handle`/`dispatch::read`'s OWN
// rehydrate-replay seed. That seed is fed to the WASM kernel alongside
// RAW HISTORICAL STEPS (verb+args exactly as originally dispatched,
// journal.rs's own top header) — a full cold replay re-plays every one
// of those steps from scratch, in whatever shape they were RECORDED
// under. Overlaying an already-translated (possibly NEWER-shaped) head
// state into the SEED a cold replay starts from would make the kernel
// see an id as already present while also replaying the very step that
// first creates it — a real, new "AlreadyExists" false refusal, not a
// fix. A lineage-capable aggregate is architecturally the same case
// Ruby's own `CommandInterpreter` already treats specially: bound to
// Postgres, it is dispatched OUTSIDE the in-memory replay engine
// entirely (`InMemoryRepository` is Ruby's Memory adapter's own
// concept, never reached for a Postgres-bound aggregate) — never
// blended into it. rust/host's own Member handling (auth.rs) already
// follows that split; these functions extend it to any aggregate the
// exported IR marks lineage-capable (`ir.json`'s `lineage.
// capable_aggregates`, Projector::Exporter.lineage), rather than
// leaving Member as a one-off.
fn head_view(storage_name: &str) -> String {
    format!("{storage_name}_head")
}

/// Every live row for one lineage-capable aggregate, already translated
/// to its current shape — `member_rows`'s own query (auth.rs), made
/// generic over `storage_name` instead of hard-typed to `"member_head"`.
pub async fn read_lineage_head_all<C: GenericClient>(
    client: &C,
    storage_name: &str,
) -> anyhow::Result<Vec<(String, serde_json::Value)>> {
    let rows = client
        .query(&format!("SELECT id, state FROM {}", quote_ident(&head_view(storage_name))), &[])
        .await?;
    Ok(rows.into_iter().map(|row| (row.get(0), row.get(1))).collect())
}

/// One row by id, already translated — `member_row_by_email`'s own
/// query (auth.rs), made generic the same way.
pub async fn read_lineage_head_by_id<C: GenericClient>(
    client: &C,
    storage_name: &str,
    id: &str,
) -> anyhow::Result<Option<serde_json::Value>> {
    let row = client
        .query_opt(
            &format!("SELECT state FROM {} WHERE id = $1", quote_ident(&head_view(storage_name))),
            &[&id],
        )
        .await?;
    Ok(row.map(|r| r.get(0)))
}

// ── ERA/APPROVAL READS — the part of `hecks_eras`/`hecks_approvals`
// a boot-time drift check (and, later, a mint executor) needs to read
// for itself, rather than trusting an externally-supplied HECKS_ERA.
// Ports of era_store.rb's own `eras`/`approval_for`/`last_ordinal`.

/// One row of `hecks_eras`, held/verified — mirrors era_store.rb's
/// `eras` method's own returned shape exactly (`ordinal`, `hash`,
/// `label`, `held_text`, `watermark`).
#[derive(Debug, Clone)]
pub struct HeldEra {
    pub ordinal: i32,
    pub hash: Option<String>,
    pub label: Option<String>,
    pub held_text: String,
    pub watermark: Option<i64>,
}

/// Every held era for one domain, in ordinal order, each verified
/// against its own raw-byte digest — an edited `held_text` refuses
/// loudly rather than silently reporting "no drift", the same
/// tamper-evidence guarantee `EraStore#verify_integrity!`'s own header
/// names. `held_digest IS NULL` (a row from before the integrity
/// column existed) is accepted unverified, matching Ruby's own
/// behavior for that case — but this function does NOT replicate
/// Ruby's own write-side backfill of that column (`backfill_frozen_
/// facts!`): a Rust-minted era always writes `held_digest` from the
/// start, so there is no legacy gap for this read path to repair, only
/// one for it to tolerate on eras a Ruby boot minted first.
pub async fn held_eras<C: GenericClient>(client: &C, domain: &str) -> anyhow::Result<Vec<HeldEra>> {
    let rows = client
        .query(
            "SELECT ordinal, hash, label, held_text, watermark, held_digest FROM hecks_eras \
             WHERE domain = $1 ORDER BY ordinal",
            &[&domain],
        )
        .await?;

    rows.into_iter()
        .map(|row| {
            let ordinal: i32 = row.get("ordinal");
            let held_text: String = row.get("held_text");
            let held_digest: Option<String> = row.get("held_digest");

            if let Some(stored) = &held_digest {
                let digest = format!("{:x}", Sha256::digest(held_text.as_bytes()));
                if &digest != stored {
                    anyhow::bail!(
                        "cannot boot {domain}: era {ordinal}'s held text does not match its own recorded digest \
                         — this row was edited outside the lineage tooling; run bin/reattest_era to acknowledge \
                         the change and re-seal it (Runtime::EraTamper's own recovery path)"
                    );
                }
            }

            Ok(HeldEra {
                ordinal,
                hash: row.get("hash"),
                label: row.get("label"),
                held_text,
                watermark: row.get("watermark"),
            })
        })
        .collect()
}

/// A Layer-3 approval, as recorded — mirrors era_store.rb's own
/// `approval_for` return shape.
#[derive(Debug, Clone)]
pub struct Approval {
    pub edge_digest: String,
    pub reviewed_ordinal: i64,
}

/// The latest approval for one shape-pair edge, if any — the latest
/// row wins (a re-approval supersedes), matching era_store.rb's own
/// `ORDER BY approved_at DESC, reviewed_ordinal DESC LIMIT 1`.
pub async fn approval_for<C: GenericClient>(
    client: &C,
    domain: &str,
    from_label: &str,
    to_label: &str,
) -> anyhow::Result<Option<Approval>> {
    let row = client
        .query_opt(
            "SELECT edge_digest, reviewed_ordinal FROM hecks_approvals \
             WHERE domain = $1 AND from_label = $2 AND to_label = $3 \
             ORDER BY approved_at DESC, reviewed_ordinal DESC LIMIT 1",
            &[&domain, &from_label, &to_label],
        )
        .await?;

    Ok(row.map(|row| Approval { edge_digest: row.get("edge_digest"), reviewed_ordinal: row.get("reviewed_ordinal") }))
}

/// The journal's own high-water ordinal — era_store.rb's own
/// `last_ordinal`, what a fresh approval binds to
/// (`record_approval!`'s `reviewed_ordinal`) and what a mint transaction
/// captures as the new era's own watermark.
pub async fn last_ordinal<C: GenericClient>(client: &C, domain: &str) -> anyhow::Result<i64> {
    let row = client
        .query_one(&format!("SELECT COALESCE(max(ordinal), 0) AS o FROM {}", quote_ident(&journal_table(domain))), &[])
        .await?;
    Ok(row.get("o"))
}

#[cfg(test)]
mod lineage_tests {
    use super::*;
    use tokio_postgres::NoTls;

    // MINTS A REAL ERA 2 — via Ruby's own LineageManager, not this
    // crate's own writes, against a scratch database with a genuinely
    // fenced (non-superuser) app role. Proves the central claim
    // `append_lineage_mutation`'s own header makes: staleness is
    // refused by Postgres's OWN RLS row policy
    // (`hecks_current_era`, mint_transaction.rb), not by any check this
    // crate performs itself. See tests/fixtures/mint_stale_era.rb,
    // itself a close port of
    // spec/adapters/driven/postgres/lineage_spec.rb's own
    // "fences a deployment's app role" setup — proven Ruby code, not
    // reinvented here.
    #[tokio::test]
    async fn a_stale_era_write_is_refused_by_postgres_rls_not_this_crate() {
        let db = "rust_host_rls_test";
        let owner_role = "rust_host_rls_owner";
        let app_role = "rust_host_rls_app";

        let script = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mint_stale_era.rb");
        let status = std::process::Command::new("ruby")
            .arg(&script)
            .arg(db)
            .arg(owner_role)
            .arg(app_role)
            .status()
            .expect("run mint_stale_era.rb -- is `ruby` on PATH?");
        assert!(status.success(), "mint_stale_era.rb failed -- see its own stderr above");

        // Connect AS the fenced app role -- the exact connection shape
        // a real deployed rust/host uses (never the table owner, which
        // bypasses RLS by default and would prove nothing).
        let (client, connection) =
            tokio_postgres::connect(&format!("host=localhost dbname={db} user={app_role}"), NoTls)
                .await
                .expect("connect as the app role");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        let state = serde_json::json!({ "cents": 100 });

        // The era this checkout speaks -- allowed.
        let current_era = LineageConfig { domain: "Ledger".to_string(), era: 2 };
        let accepted = append_lineage_mutation(
            &client,
            &current_era,
            &Mutation { aggregate: "Account", id: "current-era", operation: "save", state: &state },
        )
        .await;
        assert!(accepted.is_ok(), "writing under the CURRENT era should succeed: {accepted:?}");

        // The SUPERSEDED era -- refused by Postgres's own RLS policy.
        let stale_era = LineageConfig { domain: "Ledger".to_string(), era: 1 };
        let refused = append_lineage_mutation(
            &client,
            &stale_era,
            &Mutation { aggregate: "Account", id: "stale-era", operation: "save", state: &state },
        )
        .await;
        assert!(refused.is_err(), "writing under a SUPERSEDED era should be refused");
        let message = format!("{:#}", refused.unwrap_err()).to_lowercase();
        assert!(
            message.contains("row-level security") || message.contains("row level security"),
            "the refusal should be Postgres's RLS policy specifically, not some other error: {message}"
        );
    }

    // held_eras/approval_for/last_ordinal — proven against a REAL
    // compute-migrated era Ruby minted, not a synthetic fixture. Reuses
    // mint_and_seed_lineage_compute.rb (rust/host/tests/fixtures/), the
    // same script the differential-parity spec drives — the ONE thing
    // in this whole codebase that has ever driven the real approval
    // gate outside bin/translation_audit itself, so a real, non-empty
    // hecks_approvals row is guaranteed to exist by the time this test
    // reads it back.
    #[tokio::test]
    async fn held_eras_and_approval_for_read_exactly_what_ruby_s_own_mint_wrote() {
        let db = "rust_host_era_read_test";
        let owner_role = "rust_host_era_read_owner";
        let app_role = "rust_host_era_read_app";

        let script = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mint_and_seed_lineage_compute.rb");
        let output = std::process::Command::new("ruby")
            .arg(&script)
            .arg(db)
            .arg(owner_role)
            .arg(app_role)
            .output()
            .expect("run mint_and_seed_lineage_compute.rb -- is `ruby` on PATH?");
        assert!(
            output.status.success(),
            "mint_and_seed_lineage_compute.rb failed:\n{}",
            String::from_utf8_lossy(&output.stderr)
        );

        // Owner-authenticated, deliberately — this test reads bookkeeping
        // tables (hecks_eras, hecks_approvals) the app role has no grant
        // on by design (mint_and_seed_lineage.rb's own header explains
        // why: real deployment traffic never needs to read them, only
        // the mint path does), not the fenced data path the RLS test
        // above exists to prove.
        let (client, connection) = tokio_postgres::connect(&format!("host=localhost dbname={db} user={owner_role}"), NoTls)
            .await
            .expect("connect as owner");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        let eras = held_eras(&client, "LedgerCompute").await.expect("held_eras");
        assert_eq!(eras.len(), 2, "expected exactly the two eras mint_and_seed_lineage_compute.rb mints: {eras:?}");
        assert_eq!(eras[0].ordinal, 1);
        assert_eq!(eras[1].ordinal, 2);
        let from_label = eras[0].label.clone().expect("era 1 has a minted label");
        let to_label = eras[1].label.clone().expect("era 2 has a minted label");
        assert_ne!(from_label, to_label, "a real compute edge names two DIFFERENT shapes");

        let approval = approval_for(&client, "LedgerCompute", &from_label, &to_label)
            .await
            .expect("approval_for")
            .expect("the real approval mint_and_seed_lineage_compute.rb recorded should still be readable");
        assert!(!approval.edge_digest.is_empty());
        // Era 1 wrote two records (a, b) before the approval was
        // recorded — reviewed_ordinal binds to the journal's high-water
        // mark AT THAT MOMENT (record_approval!'s own last_ordinal
        // call), so it must be at least 2, never 0.
        assert!(approval.reviewed_ordinal >= 2, "reviewed_ordinal should reflect era 1's real writes: {}", approval.reviewed_ordinal);

        // Era 1's two writes plus era 2's one (via owner, post-mint) —
        // last_ordinal reads the SAME journal both the mint and the
        // approval bind to, so it must have advanced past the approval's
        // own reviewed_ordinal by at least the one post-mint write.
        let ordinal = last_ordinal(&client, "LedgerCompute").await.expect("last_ordinal");
        assert!(ordinal > approval.reviewed_ordinal, "the journal should have advanced since the approval was reviewed: {ordinal} vs {}", approval.reviewed_ordinal);
    }

    // THE BOOT-GATE CASE THE TEST ABOVE DOESN'T COVER: this crate's OWN
    // read, before any write is even attempted. `current_era` has to
    // tell a genuinely-unminted domain apart from a MINTED-BUT-STALE
    // one (an ordinal that once was current and still has a row, but
    // has since been superseded) — a bare existence check (what this
    // function replaced) can't distinguish those, and main.rs's boot
    // gate needs to: one case means "mint this domain", the other means
    // "redeploy with a newer HECKS_ERA". No Ruby/RLS involved here on
    // purpose — this is a plain SQL fact this crate reads for itself,
    // proven against a minimal fixture table, same as
    // dispatch::tests::provision_lineage's own reasoning for why that's
    // legitimate (current_era's query only ever reads domain/ordinal).
    #[tokio::test]
    async fn current_era_tells_unminted_apart_from_stale_and_finds_the_live_ordinal() {
        let (client, connection) = tokio_postgres::connect("host=localhost dbname=postgres", NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = connection.await;
        });
        client
            .batch_execute("CREATE TABLE IF NOT EXISTS hecks_eras (domain text, ordinal int)")
            .await
            .unwrap();
        client
            .batch_execute("DELETE FROM hecks_eras WHERE domain = 'CurrentEraFixture'")
            .await
            .unwrap();

        // A domain hecks_eras has never heard of at all.
        let unminted = current_era(&client, "CurrentEraFixture").await.unwrap();
        assert_eq!(unminted, None, "a domain with no hecks_eras rows at all has no current era");

        // Era 1 minted, then era 2 supersedes it — both rows stay on
        // file (hecks_eras is append-only, never deletes a superseded
        // row), exactly the shape a stale checkout would see.
        client
            .execute(
                "INSERT INTO hecks_eras (domain, ordinal) VALUES ($1, 1)",
                &[&"CurrentEraFixture"],
            )
            .await
            .unwrap();
        assert_eq!(
            current_era(&client, "CurrentEraFixture").await.unwrap(),
            Some(1),
            "with only era 1 on file, era 1 is current"
        );

        client
            .execute(
                "INSERT INTO hecks_eras (domain, ordinal) VALUES ($1, 2)",
                &[&"CurrentEraFixture"],
            )
            .await
            .unwrap();
        assert_eq!(
            current_era(&client, "CurrentEraFixture").await.unwrap(),
            Some(2),
            "era 1's row is still on file, but era 2 is now the live one -- \
             a bare existence check on era 1 would have missed that it's stale"
        );
    }

    // THE GENERIC READ PATH, proven against an aggregate that is NOT
    // Member — the whole point of pulling `member_row_by_email`/
    // `member_rows`'s own query shape out into `read_lineage_head_by_id`/
    // `read_lineage_head_all`. Builds the head view BY HAND the way
    // Ruby's `HeadCompiler#ensure_first_head!` would for a fresh era 1
    // (a plain `SELECT id, state FROM <storage>_head_snapshot_1`) rather
    // than reproducing Ruby's whole mint path — this test's own question
    // is "does the generic reader see what the view presents," not
    // "does Ruby compile the view correctly" (that's lineage_spec.rb's
    // job, in Ruby, already).
    #[tokio::test]
    async fn read_lineage_head_reads_any_aggregates_view_generically() {
        let (client, connection) = tokio_postgres::connect("host=localhost dbname=postgres", NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        client.batch_execute("DROP VIEW IF EXISTS widget_head").await.unwrap();
        client.batch_execute("DROP TABLE IF EXISTS widget_head_snapshot_1").await.unwrap();
        client
            .batch_execute(
                "CREATE TABLE widget_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL)",
            )
            .await
            .unwrap();
        client
            .batch_execute("CREATE VIEW widget_head AS SELECT id, state FROM widget_head_snapshot_1")
            .await
            .unwrap();

        let config = LineageConfig { domain: "Fixtures".to_string(), era: 1 };
        client
            .batch_execute("CREATE TABLE IF NOT EXISTS hecks_journal_fixtures (ordinal bigserial PRIMARY KEY, era int NOT NULL, aggregate text NOT NULL, aggregate_id text NOT NULL, operation text NOT NULL, state jsonb)")
            .await
            .unwrap();
        append_lineage_mutation(
            &client,
            &config,
            &Mutation { aggregate: "Widget", id: "widget-1", operation: "save", state: &serde_json::json!({ "name": "Gadget" }) },
        )
        .await
        .unwrap();
        append_lineage_mutation(
            &client,
            &config,
            &Mutation { aggregate: "Widget", id: "widget-2", operation: "save", state: &serde_json::json!({ "name": "Gizmo" }) },
        )
        .await
        .unwrap();

        let one = read_lineage_head_by_id(&client, "widget", "widget-1").await.unwrap();
        assert_eq!(one, Some(serde_json::json!({ "name": "Gadget" })));

        let missing = read_lineage_head_by_id(&client, "widget", "widget-nonexistent").await.unwrap();
        assert_eq!(missing, None);

        let mut all = read_lineage_head_all(&client, "widget").await.unwrap();
        all.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(
            all,
            vec![
                ("widget-1".to_string(), serde_json::json!({ "name": "Gadget" })),
                ("widget-2".to_string(), serde_json::json!({ "name": "Gizmo" })),
            ]
        );
    }

    #[tokio::test]
    async fn record_dead_letter_writes_a_real_durable_row() {
        let (client, connection) = tokio_postgres::connect("host=localhost dbname=postgres", NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = connection.await;
        });
        ensure_schema(&client).await.unwrap();
        client.batch_execute("DELETE FROM hecks_cross_domain_dead_letters").await.unwrap();

        record_dead_letter(
            &client,
            "ReviewOnFreeze",
            "Compliance",
            "Compliance::AccountFreezeReview.Open",
            &serde_json::json!({ "number": { "value": "acct-1" } }),
            "ResourceNotFoundException: function not found",
            3,
        )
        .await
        .unwrap();

        let rows = client
            .query(
                "SELECT policy, target_domain, target_verb, payload, error, attempts FROM hecks_cross_domain_dead_letters",
                &[],
            )
            .await
            .unwrap();
        assert_eq!(rows.len(), 1, "should have written exactly one row");
        let row = &rows[0];
        let policy: String = row.get(0);
        let target_domain: String = row.get(1);
        let target_verb: String = row.get(2);
        let payload: serde_json::Value = row.get(3);
        let error: String = row.get(4);
        let attempts: i32 = row.get(5);
        assert_eq!(policy, "ReviewOnFreeze");
        assert_eq!(target_domain, "Compliance");
        assert_eq!(target_verb, "Compliance::AccountFreezeReview.Open");
        assert_eq!(payload, serde_json::json!({ "number": { "value": "acct-1" } }));
        assert_eq!(error, "ResourceNotFoundException: function not found");
        assert_eq!(attempts, 3);
    }
}
