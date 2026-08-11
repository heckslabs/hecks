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
// total event volume; see docs/decisions/0018-rehydrate-replay-lambda-
// host.md for the full tradeoff.
//
// Determinism is what makes this safe to persist selectively: every
// prior journal row was, by construction, a command that succeeded the
// first time it was dispatched — replaying the exact same steps against
// the exact same (empty-start) kernel must produce the exact same
// result again. So the ONLY step in a full replay that can legitimately
// end up in `refusals` is the newest one, appended last. That's the
// entire correctness argument `append_if_accepted` below leans on.

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
}

/// The kernel's own "instances" output as of `ordinal` — what a fresh
/// `Store::from_seed` (rust/src/kernel, adf38fd's follow-up) needs to
/// stand in for a full replay. `None` before the first command this
/// journal has ever accepted (nothing to seed from yet — `dispatch::
/// handle` falls back to `Store::new()`/an empty seed, exactly today's
/// behavior for a brand-new domain).
pub async fn load_snapshot<C: GenericClient>(client: &C) -> anyhow::Result<Option<Snapshot>> {
    let rows = client.query("SELECT ordinal, seed FROM hecks_lambda_snapshot", &[]).await?;
    Ok(rows.first().map(|row| Snapshot { ordinal: row.get(0), seed: row.get(1) }))
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
pub async fn save_snapshot<C: GenericClient>(client: &C, ordinal: i64, seed: &serde_json::Value) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_lambda_snapshot (id, ordinal, seed) VALUES (true, $1, $2) \
             ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, seed = EXCLUDED.seed",
            &[&ordinal, seed],
        )
        .await?;
    Ok(())
}

// ── THE RUBY-SHAPED LINEAGE JOURNAL — an ADDITIONAL write path, not a
// replacement for the flat log above. `hecks_lambda_journal` remains
// the sole source `dispatch::handle` rehydrates from; the functions
// below write each accepted command's own mutations (the kernel's new
// "mutations" output field, adf38fd) into the SAME per-aggregate,
// era-partitioned schema Ruby's own Postgres adapter uses
// (lib/hecksagain/adapters/driven/postgres.rb + postgres/lineage.rb) —
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

/// `Naming.snake` (lib/hecksagain/naming.rb:30-35), ported verbatim — a
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

/// The SAME two-step append `Postgres#append` (postgres.rb:141-166)
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
}
