// THE REHYDRATE-AND-REPLAY JOURNAL — flat, non-era-aware, and
// deliberately domain-agnostic: one table for the WHOLE domain's
// command history, not one per aggregate. Rust has no era/lineage
// concept at all (a known, already-documented gap from ADR 0011), and
// rust/host has no type information about aggregates/commands (that
// knowledge lives only inside the compiled `.wasm` module, which this
// crate treats as opaque) — so filtering "which prior commands matter
// for this one" isn't something rust/host can safely do on its own.
// Replaying the FULL log on every invocation is the simplest correct
// answer for a company-internal tool with modest total event volume;
// see docs/decisions/0018-rehydrate-replay-lambda-host.md for the full
// tradeoff.
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

pub async fn append<C: GenericClient>(
    client: &C,
    verb: &str,
    args: &serde_json::Value,
) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_lambda_journal (verb, args) VALUES ($1, $2)",
            &[&verb, &args],
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
// deliberately doesn't have — ADR 0007). `era_exists` below is a
// boot-time READ, refusing cleanly if Ruby hasn't provisioned the
// configured domain/era yet, and a write for a stale era refuses
// through Postgres's own RLS row policy (`hecks_current_era`,
// postgres/lineage/mint_transaction.rb) — not a second, Rust-side
// staleness check duplicating that logic.

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
fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn journal_table(domain: &str) -> String {
    format!("hecks_journal_{}", snake(domain))
}

fn head_snapshot_table(qualified_aggregate: &str, era: i32) -> String {
    format!("{}_head_snapshot_{}", storage_name(qualified_aggregate), era)
}

/// The boot-time gate: does Ruby's own `hecks_eras` already hold a row
/// for this exact domain/era? If not, this binary was deployed against
/// a domain/era Ruby's LineageManager hasn't provisioned yet (or the
/// era ordinal is simply wrong) — `main.rs` refuses to start rather
/// than write into tables that may not exist.
pub async fn era_exists(client: &Client, domain: &str, era: i32) -> anyhow::Result<bool> {
    let rows = client
        .query(
            "SELECT 1 FROM hecks_eras WHERE domain = $1 AND ordinal = $2",
            &[&domain, &era],
        )
        .await?;
    Ok(!rows.is_empty())
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
}
