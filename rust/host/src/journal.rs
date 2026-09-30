//! Flat, domain-agnostic journal of every command this domain has ever
//! accepted, replayed in full on each invocation rather than filtered (ADR 0018).

use anyhow::Context;
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
    // Single-row cache of the kernel's last "instances" output; the
    // `boolean PRIMARY KEY DEFAULT true CHECK (id)` trick enforces at
    // most one row. See `load_snapshot`/`save_snapshot`.
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_lambda_snapshot (
                id      boolean PRIMARY KEY DEFAULT true CHECK (id),
                ordinal bigint  NOT NULL,
                seed    jsonb   NOT NULL
            )",
        )
        .await?;
    // Additive column; `DEFAULT false` makes every pre-existing row read
    // as "not backfilled yet", the correct value with no separate migration.
    client
        .batch_execute(
            "ALTER TABLE hecks_lambda_snapshot ADD COLUMN IF NOT EXISTS sagas_backfilled boolean NOT NULL DEFAULT false",
        )
        .await?;
    // One row per in-flight saga instance (unlike the single-row snapshot
    // above): sagas are numerous and mostly independent. No `ordinal`
    // column — always written inside dispatch::handle's advisory-locked
    // transaction, so plain overwrite-in-place is correct (see dispatch.rs).
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
    // Additive column, same backfill idiom as `sagas_backfilled` above;
    // `DEFAULT '[]'::jsonb` gives every pre-existing saga row an empty
    // ledger instead of requiring a separate migration.
    client
        .batch_execute(
            "ALTER TABLE hecks_lambda_sagas ADD COLUMN IF NOT EXISTS completed_compensations jsonb NOT NULL DEFAULT '[]'::jsonb",
        )
        .await?;
    // Durable record of a cross-domain delivery that exhausted retries;
    // see `record_dead_letter` below. Flat and domain-agnostic like
    // `hecks_lambda_journal` — one deployed Lambda has only one source domain.
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

/// Durably records a cross-domain delivery that exhausted every retry.
/// Written post-commit — a failure here must never roll back the local command.
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

/// Every command ever accepted, in dispatch order, as `{"verb","args"}` steps.
/// Generic over `GenericClient` so callers can run it inside their own transaction.
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

/// Steps recorded after `ordinal` — what remains to replay on top of a
/// snapshot taken as of that ordinal (normally empty).
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

/// The kernel's cached "instances" output as of `ordinal`, used to skip a
/// full replay from empty state.
pub struct Snapshot {
    pub ordinal: i64,
    pub seed: serde_json::Value,
    /// One-time latch: false only for a snapshot written before saga
    /// durability shipped, never a live signal about current saga state.
    pub sagas_backfilled: bool,
}

/// The domain's cached snapshot, if one has ever been written. `None`
/// before the first accepted command, when there's nothing to seed from yet.
pub async fn load_snapshot<C: GenericClient>(client: &C) -> anyhow::Result<Option<Snapshot>> {
    let rows = client
        .query("SELECT ordinal, seed, sagas_backfilled FROM hecks_lambda_snapshot", &[])
        .await?;
    Ok(rows.first().map(|row| Snapshot { ordinal: row.get(0), seed: row.get(1), sagas_backfilled: row.get(2) }))
}

/// Returns the new journal row's ordinal, for `save_snapshot` to pair with it.
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

/// Upserts the one-row snapshot cache at `ordinal`. Always sets
/// `sagas_backfilled = true`; only a row written before that column
/// existed can ever read back `false`.
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

/// One live saga/process-manager instance, as stored in `hecks_lambda_sagas`.
pub struct SagaRow {
    pub process_manager: String,
    pub correlation: String,
    pub state: String,
    pub memory: serde_json::Value,
    pub completed_compensations: serde_json::Value,
}

/// Every live saga instance for this domain, read once per invocation to
/// seed the kernel's in-memory `sagas` map.
pub async fn load_sagas<C: GenericClient>(client: &C) -> anyhow::Result<Vec<SagaRow>> {
    let rows = client
        .query(
            "SELECT process_manager, correlation, state, memory, completed_compensations FROM hecks_lambda_sagas",
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
            completed_compensations: row.get(4),
        })
        .collect())
}

/// Upserts one live saga instance's state. Must run in the same
/// transaction as `append`, never a post-commit connection.
pub async fn save_saga<C: GenericClient>(
    client: &C,
    process_manager: &str,
    correlation: &str,
    state: &str,
    memory: &serde_json::Value,
    completed_compensations: &serde_json::Value,
) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_lambda_sagas (process_manager, correlation, state, memory, completed_compensations) \
             VALUES ($1, $2, $3, $4, $5) \
             ON CONFLICT (process_manager, correlation) DO UPDATE \
             SET state = EXCLUDED.state, memory = EXCLUDED.memory, completed_compensations = EXCLUDED.completed_compensations",
            &[&process_manager, &correlation, &state, memory, completed_compensations],
        )
        .await?;
    Ok(())
}

/// Removes one saga instance that ended.
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

/// Which domain journal this binary writes as, and which era. Read from
/// `HECKS_DOMAIN`/main.rs's boot-time mint decision, never computed here.
pub struct LineageConfig {
    pub domain: String,
    /// `None` when lineage isn't provisioned for this domain (ADR 0034).
    pub era: Option<i32>,
    /// Aggregates mirrored into era-shaped head snapshots; `None` means all.
    pub mirrored: Option<std::collections::BTreeSet<String>>,
}

impl LineageConfig {
    /// Whether `qualified_aggregate` is mirrored into the era-shaped head
    /// snapshots.
    pub fn mirrors(&self, qualified_aggregate: &str) -> bool {
        match &self.mirrored {
            None => true,
            Some(capable) => capable.contains(qualified_aggregate),
        }
    }
}

/// Ports `Naming.snake` (lib/hecks/naming.rb) verbatim — must match Ruby
/// exactly so both runtimes derive the same storage names.
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

/// `aggregate.storage_name` ported from ir/aggregate.rb — demodulizes a
/// qualified name like `"Banking::Customer"` to `"Customer"` before snaking it.
fn storage_name(qualified_aggregate: &str) -> String {
    let short = qualified_aggregate.rsplit("::").next().unwrap_or(qualified_aggregate);
    snake(short)
}

/// Quotes a Postgres identifier `PG::Connection.quote_ident`-style —
/// needed since table names can't be bound as query parameters.
pub(crate) fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn journal_table(domain: &str) -> String {
    format!("hecks_journal_{}", snake(domain))
}

/// Postgres's NAMEDATALEN-1 limit — an identifier over this length is
/// silently truncated, never refused, so two overlong names sharing a
/// prefix would otherwise collide.
const POSTGRES_IDENTIFIER_LIMIT: usize = 63;

/// Same algorithm as `Lineage#qualified_name` (lineage.rb): 63-byte limit,
/// SHA256 suffix, domain-qualified so two domains' storage names can't
/// collide (ADR 0059).
pub(crate) fn qualified_name(domain: &str, suffix: &str) -> String {
    let full = format!("{}_{}", snake(domain), suffix);
    if full.len() <= POSTGRES_IDENTIFIER_LIMIT {
        return full;
    }

    let digest = format!("{:x}", Sha256::digest(full.as_bytes()));
    let digest = &digest[0..8];
    let keep = POSTGRES_IDENTIFIER_LIMIT - digest.len() - 1;
    format!("{}_{}", &full[0..keep], digest)
}

fn head_snapshot_table(domain: &str, qualified_aggregate: &str, era: i32) -> String {
    qualified_name(domain, &format!("{}_head_snapshot_{}", storage_name(qualified_aggregate), era))
}

/// The highest era ordinal on file for `domain`, not a bare existence
/// check — `hecks_eras` is append-only, so a stale checkout still has a row.
pub async fn current_era(client: &Client, domain: &str) -> anyhow::Result<Option<i32>> {
    let rows = client
        .query(
            "SELECT ordinal FROM hecks_eras WHERE domain = $1 ORDER BY ordinal DESC LIMIT 1",
            &[&domain],
        )
        .await?;
    Ok(rows.first().map(|row| row.get(0)))
}

/// One `MutationRecord` from the kernel's JSON output, parsed generically
/// since rust/host never links the kernel crate directly (ADR 0012).
pub struct Mutation<'a> {
    pub aggregate: &'a str,
    pub id: &'a str,
    pub operation: &'a str,
    pub state: &'a serde_json::Value,
}

/// Mirrors `PostgresEra#append`'s two-step write: journal insert, then a
/// head-snapshot upsert that never regresses on a stale/reordered write.
pub async fn append_lineage_mutation<C: GenericClient>(
    client: &C,
    config: &LineageConfig,
    mutation: &Mutation<'_>,
) -> anyhow::Result<()> {
    // ADR 0034 — the one chokepoint every lineage write passes through;
    // dispatch::handle already checks `era.is_some()` for ordinary
    // commands, so this bail! is the backstop for other callers.
    let Some(era) = config.era else {
        anyhow::bail!(
            "cannot append a lineage mutation for {}::{}: no era is active — the lineage subsystem was never \
             initialized for this domain",
            config.domain,
            mutation.aggregate
        );
    };

    if mutation.operation != "save" {
        anyhow::bail!(
            "hecks_journal_{}: unsupported operation {:?} — only \"save\" is generated today",
            snake(&config.domain),
            mutation.operation
        );
    }

    let journal = journal_table(&config.domain);
    let snapshot = head_snapshot_table(&config.domain, mutation.aggregate, era);
    let storage = storage_name(mutation.aggregate);

    // Named per-statement: tokio_postgres's Display for a db error is
    // just "db error" — the real message is on `source()`, which
    // `main.rs` surfaces via `{:#}` formatting.
    let row = client
        .query_one(
            &format!(
                "INSERT INTO {} (era, aggregate, aggregate_id, operation, state) \
                 VALUES ($1, $2, $3, $4, $5) RETURNING ordinal",
                quote_ident(&journal)
            ),
            &[&era, &storage, &mutation.id, &mutation.operation, &mutation.state],
        )
        .await
        .with_context(|| format!("journalling {} #{} into {journal} at era {era}", mutation.aggregate, mutation.id))?;
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
        .await
        .with_context(|| format!("upserting {} #{} into {snapshot}", mutation.aggregate, mutation.id))?;

    Ok(())
}

// Not wired into dispatch::handle's replay seed — overlaying translated
// head state onto raw replayed steps would cause false "AlreadyExists" refusals.
pub(crate) fn head_view(domain: &str, storage_name: &str) -> String {
    qualified_name(domain, &format!("{storage_name}_head"))
}

/// Every row for one lineage-capable aggregate, already translated to its
/// current shape (reads the same head view Ruby's `Adapters::Postgres` does).
pub async fn read_lineage_head_all<C: GenericClient>(
    client: &C,
    domain: &str,
    storage_name: &str,
) -> anyhow::Result<Vec<(String, serde_json::Value)>> {
    let rows = client
        .query(&format!("SELECT id, state FROM {}", quote_ident(&head_view(domain, storage_name))), &[])
        .await?;
    Ok(rows.into_iter().map(|row| (row.get(0), row.get(1))).collect())
}

/// One row by id, already translated to its current shape.
pub async fn read_lineage_head_by_id<C: GenericClient>(
    client: &C,
    domain: &str,
    storage_name: &str,
    id: &str,
) -> anyhow::Result<Option<serde_json::Value>> {
    let row = client
        .query_opt(
            &format!("SELECT state FROM {} WHERE id = $1", quote_ident(&head_view(domain, storage_name))),
            &[&id],
        )
        .await?;
    Ok(row.map(|r| r.get(0)))
}

/// One row of `hecks_eras`, mirroring era_store.rb's `eras` shape.
#[derive(Debug, Clone)]
pub struct HeldEra {
    pub ordinal: i32,
    pub hash: Option<String>,
    pub label: Option<String>,
    pub held_text: String,
    pub watermark: Option<i64>,
}

/// Every held era for `domain`, each verified against its own digest — an
/// edited `held_text` refuses loudly instead of silently reporting no drift.
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
                         — this row was edited outside the lineage tooling; run hecks reattest to acknowledge \
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

/// A Layer-3 approval, as recorded — mirrors era_store.rb's `approval_for`.
#[derive(Debug, Clone)]
pub struct Approval {
    pub edge_digest: String,
    pub reviewed_ordinal: i64,
}

/// The latest approval for one shape-pair edge, if any (latest wins).
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

/// Writes an approval into the journal, bound to the journal's tip as it stands, as
/// `LineageStore#record_approval!` does; how a committed approval joins the single history.
pub async fn record_approval<C: GenericClient>(
    client: &C,
    domain: &str,
    from_label: &str,
    to_label: &str,
    edge_digest: &str,
) -> anyhow::Result<()> {
    let tip = last_ordinal(client, domain).await?;
    client
        .execute(
            "INSERT INTO hecks_approvals (domain, from_label, to_label, edge_digest, reviewed_ordinal) \
             VALUES ($1, $2, $3, $4, $5)",
            &[&domain, &from_label, &to_label, &edge_digest, &tip],
        )
        .await?;
    Ok(())
}

/// The journal's high-water ordinal — what a fresh approval binds to and
/// what a mint transaction captures as the new era's watermark.
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

    // Mints a real era 2 via Ruby's LineageManager (not this crate's own
    // writes) against a scratch DB with a genuinely fenced app role — so
    // this proves staleness is refused by Postgres RLS, not a check here.
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

        // The fenced app role — the same connection shape a real deployed
        // rust/host uses (never the table-owning role, which bypasses RLS).
        let (client, connection) =
            tokio_postgres::connect(&crate::test_pg::conninfo_as(&db, &app_role), NoTls)
                .await
                .expect("connect as the app role");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        let state = serde_json::json!({ "cents": 100 });

        // The era this checkout speaks -- allowed.
        let current_era = LineageConfig { domain: "Ledger".to_string(), era: Some(2), mirrored: None };
        let accepted = append_lineage_mutation(
            &client,
            &current_era,
            &Mutation { aggregate: "Account", id: "current-era", operation: "save", state: &state },
        )
        .await;
        assert!(accepted.is_ok(), "writing under the CURRENT era should succeed: {accepted:?}");

        // The superseded era -- refused by Postgres's own RLS policy.
        let stale_era = LineageConfig { domain: "Ledger".to_string(), era: Some(1), mirrored: None };
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

    // Proven against a real compute-migrated era Ruby minted, not a
    // synthetic fixture, so a real hecks_approvals row is guaranteed
    // to exist by the time this test reads it back.
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

        // Owner-authenticated: hecks_eras/hecks_approvals aren't grantable
        // to the app role by design — only the mint path reads them, not
        // the RLS-fenced data path the test above exists to prove.
        let (client, connection) = tokio_postgres::connect(&crate::test_pg::conninfo_as(&db, &owner_role), NoTls)
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
        // reviewed_ordinal binds to the journal's high-water mark at
        // approval time; era 1's two prior writes mean it must be >= 2.
        assert!(approval.reviewed_ordinal >= 2, "reviewed_ordinal should reflect era 1's real writes: {}", approval.reviewed_ordinal);

        // last_ordinal must have advanced past the approval's own
        // reviewed_ordinal by the one post-mint write.
        let ordinal = last_ordinal(&client, "LedgerCompute").await.expect("last_ordinal");
        assert!(ordinal > approval.reviewed_ordinal, "the journal should have advanced since the approval was reviewed: {ordinal} vs {}", approval.reviewed_ordinal);
    }

    // The boot-gate case the RLS test doesn't cover: this crate's own
    // read, before any write is attempted. Proves `current_era` tells a
    // genuinely-unminted domain apart from a minted-but-stale one, which
    // a bare existence check can't.
    #[tokio::test]
    async fn current_era_tells_unminted_apart_from_stale_and_finds_the_live_ordinal() {
        let (client, connection) = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls)
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

        // Era 1 minted, then era 2 supersedes it; hecks_eras is
        // append-only, so both rows remain on file.
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

    // Proven against an aggregate that isn't Member — the whole point of
    // extracting `member_row_by_email`/`member_rows`'s query into these
    // generic functions. Builds the head view by hand rather than
    // reproducing Ruby's mint path; that correctness is lineage_spec.rb's job.
    #[tokio::test]
    async fn read_lineage_head_reads_any_aggregates_view_generically() {
        let (client, connection) = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        // Domain-qualified (ADR 0059); snake("Fixtures") == "fixtures".
        client.batch_execute("DROP VIEW IF EXISTS fixtures_widget_head").await.unwrap();
        client.batch_execute("DROP TABLE IF EXISTS fixtures_widget_head_snapshot_1").await.unwrap();
        client
            .batch_execute(
                "CREATE TABLE fixtures_widget_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL)",
            )
            .await
            .unwrap();
        client
            .batch_execute("CREATE VIEW fixtures_widget_head AS SELECT id, state FROM fixtures_widget_head_snapshot_1")
            .await
            .unwrap();

        let config = LineageConfig { domain: "Fixtures".to_string(), era: Some(1), mirrored: None };
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

        let one = read_lineage_head_by_id(&client, "Fixtures", "widget", "widget-1").await.unwrap();
        assert_eq!(one, Some(serde_json::json!({ "name": "Gadget" })));

        let missing = read_lineage_head_by_id(&client, "Fixtures", "widget", "widget-nonexistent").await.unwrap();
        assert_eq!(missing, None);

        let mut all = read_lineage_head_all(&client, "Fixtures", "widget").await.unwrap();
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
        let (client, connection) = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls)
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
