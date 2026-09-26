// **The Rust mint executor** — the biggest, most consequential piece of
// ADR-0030-in-progress: Rust performs a real era mint itself, against
// real Postgres, using SQL Ruby's own `Translation::RuleCompiler`
// precompiled at build time (`ir.json`'s `translations` key — see
// `crate::storage_shape` and `Exporter.translation_aggregate`'s own
// header for why this crate never needs its own SQL compiler).
//
// A faithful, function-for-function port of `lib/hecks/adapters/
// driven/postgres_era/lineage/{provisioning,mint_transaction,
// head_compiler,resumable_backfill}.rb`'s combined behavior — every SQL
// string below is the same text those files issue, gathered verbatim,
// not re-derived from a description. Two deliberate, documented
// narrowings from what Ruby does, both because this crate has no
// bluebook parser (that's `rust/parser`, never linked into `rust/
// host` — ADR 0012's own boundary):
//
//   1. Ruby's `hold_first!` leaves era 1 unnamed (hash/label NULL)
//      until something later needs to leave it — `ensure_named!` names
//      it lazily by re-parsing its own frozen held_text
//      (`shadow(era[:held_text])`). This crate names era 1 eagerly,
//      at hold time — it already has its own shape hash in hand (that's
//      why it's holding), so there's no lazy-naming benefit to chase,
//      and it sidesteps ever needing to re-parse held bluebook text.
//   2. If this crate ever finds an existing held era with a NULL hash
//      (one Ruby minted and never named, because nothing has drifted
//      away from it yet), it refuses to mint forward from it — that
//      naming step genuinely needs the parser Ruby has and this crate
//      doesn't. Named explicitly in the refusal, not a silent stall.
//
// Always uses the full (non-layered) chain build — `head_compiler.rb`'s
// own `layered_chain_sql` optimization (era N built from era N-1's
// matview instead of the raw ancestor tail) is not ported. It is no longer
// what keeps a long chain affordable: the full chain's cost used to grow
// exponentially with the number of eras (see `chain_sql`), and it is now
// linear because every CTE in it is `MATERIALIZED`. The layered build would
// still save re-reading the ancestor tail on each mint, which is worth adding
// once a deployment's journal, not its era count, makes that scan expensive.

use anyhow::Context;
use crate::journal::quote_ident;
use crate::reference_transform;
use crate::reference_validate;
use crate::storage_shape;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio_postgres::GenericClient;

// ───────────────────────── naming ─────────────────────────

fn journal_table(domain: &str) -> String {
    format!("hecks_journal_{}", storage_shape_snake(domain))
}

fn sequence(domain: &str) -> String {
    format!("{}_ordinal", journal_table(domain))
}

fn partition(domain: &str, era: i32) -> String {
    format!("{}_era_{era}", journal_table(domain))
}

// Domain-qualified (docs/decisions/0059), the same `crate::journal::
// qualified_name`/`Lineage#qualified_name` algorithm both other places
// this naming scheme is computed already use — delegated to, not
// reimplemented a third time, the same reasoning `storage_shape_snake`
// below already gives for `snake`. Without the domain qualifier, two
// different domains bound to PostgresEra against the same database,
// each declaring an aggregate whose own name snake_cases to the same
// storage_name, would make this file's own mint path (`compile_head`/
// `ensure_first_head`/`grant_role`) derive the exact same physical
// relations as the other domain's — this crate's own copy of the exact
// collision docs/decisions/0059 documents for Ruby.
fn head_snapshot(domain: &str, storage_name: &str, era: i32) -> String {
    crate::journal::qualified_name(domain, &format!("{storage_name}_head_snapshot_{era}"))
}

fn matview(domain: &str, storage_name: &str, era: i32, label: &str) -> String {
    crate::journal::qualified_name(domain, &format!("{storage_name}_lineage_{era}_{label}"))
}

fn head_view(domain: &str, storage_name: &str) -> String {
    crate::journal::qualified_name(domain, &format!("{storage_name}_head"))
}

// `Naming.snake` — same pure syntactic transform `crate::journal::snake`
// already ports; reused directly rather than duplicated a second time.
fn storage_shape_snake(name: &str) -> String {
    crate::journal::snake(name)
}

fn text_literal(text: &str) -> String {
    format!("'{}'", text.replace('\'', "''"))
}

// ───────────────────────── edge model ─────────────────────────

/// One aggregate's own bind, as `ensure_base!`'s caller (the boot gate)
/// already knows it — `{name, storage_name}`, the same pair `ir.json`'s
/// own `lineage.capable_aggregates` carries (`Exporter.lineage`).
#[derive(Debug, Clone)]
pub struct Aggregate {
    pub name: String,
    pub storage_name: String,
}

/// One aggregate's rules within one edge — mirrors `Exporter.
/// translation_aggregate`'s own exported shape, read back out of
/// `ir.json`'s `translations` key.
#[derive(Debug, Clone)]
pub struct EdgeAggregate {
    pub name: String,
    pub was: Option<String>,
    pub has_compute_or_rekey: bool,
    pub compiled_state_expression: String,
    pub compiled_id_expression: Option<String>,
}

/// One translation edge — mirrors `Translation`'s own shape
/// (`Exporter.translation_hash`).
#[derive(Debug, Clone)]
pub struct Edge {
    pub from: String,
    pub to: String,
    pub aggregates: Vec<EdgeAggregate>,
}

impl Edge {
    fn for_aggregate(&self, name: &str) -> Option<&EdgeAggregate> {
        self.aggregates.iter().find(|a| a.name == name)
    }
}

/// `ir.json`'s `translations` array, parsed and filtered to one
/// domain — the same JSON `Exporter.translations` writes, read back
/// generically (this crate links no kernel/codegen crate, per ADR
/// 0012 — `serde_json::Value` navigation, not a generated type, matches
/// how `crate::ir` already reads everything else in this sidecar).
pub fn parse_edges(ir: &Value, domain: &str) -> Vec<Edge> {
    ir.get("translations")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter(|edge| edge.get("domain").and_then(Value::as_str) == Some(domain))
                .map(|edge| Edge {
                    from: edge.get("from").and_then(Value::as_str).unwrap_or_default().to_string(),
                    to: edge.get("to").and_then(Value::as_str).unwrap_or_default().to_string(),
                    aggregates: edge
                        .get("aggregates")
                        .and_then(Value::as_array)
                        .map(|aggs| {
                            aggs.iter()
                                .map(|agg| EdgeAggregate {
                                    name: agg.get("name").and_then(Value::as_str).unwrap_or_default().to_string(),
                                    was: agg.get("was").and_then(Value::as_str).map(str::to_string),
                                    has_compute_or_rekey: !agg.get("computes").and_then(Value::as_array).map(Vec::is_empty).unwrap_or(true)
                                        || !agg.get("rekeys").and_then(Value::as_array).map(Vec::is_empty).unwrap_or(true),
                                    compiled_state_expression: agg
                                        .get("compiled_state_expression")
                                        .and_then(Value::as_str)
                                        .unwrap_or("state")
                                        .to_string(),
                                    compiled_id_expression: agg.get("compiled_id_expression").and_then(Value::as_str).map(str::to_string),
                                })
                                .collect()
                        })
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The one edge chain from era 1's label to `to_label`, in mint order —
/// `LineageManager#edge_chain`'s own logic, walked over the `edges`
/// list (`ir.json`'s full, unordered set for this domain) rather than
/// a live registry. Refuses (returns Err) exactly where Ruby's own
/// `edge_chain` does: a broken chain — some era's label has no edge
/// leaving it toward the next.
pub fn edge_chain<'a>(edges: &'a [Edge], labels: &[String]) -> anyhow::Result<Vec<&'a Edge>> {
    (0..labels.len() - 1)
        .map(|index| {
            edges
                .iter()
                .find(|edge| edge.from == labels[index] && edge.to == labels[index + 1])
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "the edge chain is broken at era {} — no translation leads {} to {}; restore bluebook/translations/",
                        index + 1,
                        labels[index],
                        labels[index + 1]
                    )
                })
        })
        .collect()
}

// ───────────────────────── boot decision ─────────────────────────

/// What `main()`'s boot gate should do, given every held era for this
/// domain and this binary's own freshly-computed shape label — pulled
/// out of `main.rs` as a pure function (no `GenericClient`, no I/O) so
/// the four-way branch is directly unit-testable without a real
/// Postgres. `main.rs` matches on this and does nothing else to decide
/// — every DB-touching consequence (`hold_first`, `edge_chain`,
/// `approval::check`, `mint_era`) still lives there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BootDecision {
    /// A held era already names this exact shape — boot at it,
    /// whichever ordinal. RLS itself refuses a write if this turns out
    /// to be superseded by the time a mutation actually lands.
    UseExisting { ordinal: i32 },
    /// No held era at all — this domain is brand new to this database.
    /// Mint era 1 (`mint::hold_first`).
    HoldFirst,
    /// The latest held era has a different shape than this binary's
    /// own — walk the translation-edge chain from it and mint the next
    /// ordinal (`mint::mint_era`).
    Mint { ordinal: i32, from_ordinal: i32, from_label: String },
    /// The latest held era has no label yet (Ruby minted it but never
    /// named it) — this crate has no bluebook parser to name it with,
    /// so it can't tell whether that era even matches its own shape.
    /// Refuse rather than guess.
    LatestUnnamed { ordinal: i32 },
}

impl BootDecision {
    /// The outcome's name, as the boot log reports it.
    pub fn name(&self) -> &'static str {
        match self {
            BootDecision::UseExisting { .. } => "use_existing",
            BootDecision::HoldFirst => "hold_first",
            BootDecision::Mint { .. } => "mint",
            BootDecision::LatestUnnamed { .. } => "latest_unnamed",
        }
    }
}

/// The pure decision itself — the four branches `main.rs`'s boot gate
/// calls into, rather than inlining directly. `held` must already be in
/// ordinal order (as `journal::held_eras` returns it).
pub fn decide_boot_action(held: &[crate::journal::HeldEra], my_label: &str) -> BootDecision {
    if let Some(matching) = held.iter().find(|held_era| held_era.label.as_deref() == Some(my_label)) {
        return BootDecision::UseExisting { ordinal: matching.ordinal };
    }
    if held.is_empty() {
        return BootDecision::HoldFirst;
    }
    let latest = held.last().expect("checked non-empty above");
    match &latest.label {
        None => BootDecision::LatestUnnamed { ordinal: latest.ordinal },
        Some(label) => BootDecision::Mint {
            ordinal: latest.ordinal + 1,
            from_ordinal: latest.ordinal,
            from_label: label.clone(),
        },
    }
}

// ───────────────────────── provisioning ─────────────────────────

async fn provisioner<C: GenericClient>(client: &C, journal: &str) -> anyhow::Result<bool> {
    let row = client
        .query_opt(
            "SELECT pg_get_userbyid(relowner) = current_user AS owned FROM pg_class WHERE relname = $1 AND pg_table_is_visible(oid)",
            &[&journal],
        )
        .await?;
    Ok(match row {
        None => true,
        Some(row) => row.get::<_, bool>("owned"),
    })
}

async fn partition_attached<C: GenericClient>(client: &C, partition_name: &str, journal: &str) -> anyhow::Result<bool> {
    let row = client
        .query_opt(
            "SELECT 1 FROM pg_inherits i \
             JOIN pg_class child ON child.oid = i.inhrelid \
             JOIN pg_class parent ON parent.oid = i.inhparent \
             WHERE child.relname = $1 AND parent.relname = $2 \
             AND pg_table_is_visible(child.oid) AND pg_table_is_visible(parent.oid)",
            &[&partition_name, &journal],
        )
        .await?;
    Ok(row.is_some())
}

async fn ensure_partition<C: GenericClient>(client: &C, domain: &str, era: i32) -> anyhow::Result<()> {
    let journal = journal_table(domain);
    let part = partition(domain, era);
    if partition_attached(client, &part, &journal).await? {
        return Ok(());
    }
    client
        .batch_execute(&format!("CREATE TABLE IF NOT EXISTS {} (LIKE {} INCLUDING DEFAULTS)", quote_ident(&part), quote_ident(&journal)))
        .await?;
    client
        .batch_execute(&format!("ALTER TABLE {} ATTACH PARTITION {} FOR VALUES IN ({era})", quote_ident(&journal), quote_ident(&part)))
        .await?;
    Ok(())
}

async fn install_transforms<C: GenericClient>(client: &C) -> anyhow::Result<()> {
    const FUNCTIONS: &[&str] = &[
        r#"CREATE OR REPLACE FUNCTION hecks_tr_extract(state jsonb, path text[], OUT remaining jsonb, OUT value jsonb, OUT present boolean)
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE parent jsonb; leaf text;
BEGIN
  remaining := state;
  present := false;
  leaf := path[array_upper(path, 1)];
  IF array_length(path, 1) = 1 THEN
    IF state ? leaf THEN
      present := true;
      value := state -> leaf;
      remaining := state - leaf;
    END IF;
    RETURN;
  END IF;
  parent := state #> path[1:array_upper(path, 1) - 1];
  IF jsonb_typeof(parent) = 'object' AND parent ? leaf THEN
    present := true;
    value := parent -> leaf;
    parent := parent - leaf;
    IF parent = '{}'::jsonb THEN
      remaining := state - path[1];
    ELSE
      remaining := jsonb_set(state, path[1:array_upper(path, 1) - 1], parent);
    END IF;
  END IF;
END $fn$"#,
        r#"CREATE OR REPLACE FUNCTION hecks_tr_insert(state jsonb, path text[], value jsonb, rule_label text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $fn$
BEGIN
  IF array_length(path, 1) = 1 THEN
    RETURN state || jsonb_build_object(path[1], value);
  END IF;
  IF state ? path[1] AND jsonb_typeof(state -> path[1]) <> 'object' THEN
    RAISE EXCEPTION 'cannot %: % already holds %, not a value this can nest under — moving into it would discard that value silently. Rename or drop % first.',
      rule_label, path[1], state -> path[1], path[1];
  END IF;
  IF state -> path[1] IS NULL THEN
    state := state || jsonb_build_object(path[1], '{}'::jsonb);
  END IF;
  RETURN jsonb_set(state, path, value);
END $fn$"#,
        r#"CREATE OR REPLACE FUNCTION hecks_tr_rename(state jsonb, old_name text, new_name text) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE WHEN state ? old_name
    THEN (state - old_name) || jsonb_build_object(new_name, state -> old_name)
    ELSE state END
$fn$"#,
        r#"CREATE OR REPLACE FUNCTION hecks_tr_move(state jsonb, from_path text[], to_path text[], rule_label text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE extracted record;
BEGIN
  SELECT * INTO extracted FROM hecks_tr_extract(state, from_path);
  IF NOT extracted.present THEN RETURN state; END IF;
  RETURN hecks_tr_insert(extracted.remaining, to_path, extracted.value, rule_label);
END $fn$"#,
        r#"CREATE OR REPLACE FUNCTION hecks_tr_convert(state jsonb, from_path text[], to_path text[], pairs jsonb, from_label text, rule_label text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE extracted record; pair jsonb;
BEGIN
  SELECT * INTO extracted FROM hecks_tr_extract(state, from_path);
  IF NOT extracted.present THEN RETURN state; END IF;
  FOR pair IN SELECT * FROM jsonb_array_elements(pairs) LOOP
    IF pair -> 0 = extracted.value THEN
      RETURN hecks_tr_insert(extracted.remaining, to_path, pair -> 1, rule_label);
    END IF;
  END LOOP;
  RAISE EXCEPTION 'cannot translate %: % has no mapping in its convert''s values: table. Add % => ... to cover it.',
    from_label, extracted.value, extracted.value;
END $fn$"#,
        r#"CREATE OR REPLACE FUNCTION hecks_tr_drop(state jsonb, path text[]) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE extracted record;
BEGIN
  SELECT * INTO extracted FROM hecks_tr_extract(state, path);
  RETURN extracted.remaining;
END $fn$"#,
    ];
    for sql in FUNCTIONS {
        client.batch_execute(sql).await?;
    }
    Ok(())
}

/// `ensure_base!` — provisions everything a domain needs once, ever:
/// the bookkeeping tables, the journal (partitioned, era 1 attached),
/// RLS enablement, the six `hecks_tr_*` functions. Idempotent (every
/// statement is `IF NOT EXISTS`/`ADD COLUMN IF NOT EXISTS`), gated by
/// `provisioner?` the same way Ruby's own is — a non-owner role that
/// merely reads through this crate's generic lineage functions has no
/// business running DDL, and `pg_class`'s own ownership fact is the
/// honest way to tell the two apart.
pub async fn ensure_base<C: GenericClient>(client: &C, domain: &str) -> anyhow::Result<()> {
    let journal = journal_table(domain);
    if !provisioner(client, &journal).await? {
        return Ok(());
    }

    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_eras (\
             domain text NOT NULL, ordinal int NOT NULL, hash text, label text, \
             held_text text NOT NULL, watermark bigint, \
             PRIMARY KEY (domain, ordinal))",
        )
        .await?;
    client.batch_execute("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_digest text").await?;
    client.batch_execute("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_projection jsonb").await?;
    client.batch_execute("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS canon_form int").await?;
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_era_texts (\
             domain text NOT NULL, ordinal int NOT NULL, digest text NOT NULL, held_text text NOT NULL, \
             archived_at timestamptz NOT NULL DEFAULT now(), \
             PRIMARY KEY (domain, ordinal, digest))",
        )
        .await?;
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_approvals (\
             domain text NOT NULL, from_label text NOT NULL, to_label text NOT NULL, \
             edge_digest text NOT NULL, reviewed_ordinal bigint NOT NULL, \
             approved_at timestamptz NOT NULL DEFAULT now())",
        )
        .await?;
    client.batch_execute("CREATE TABLE IF NOT EXISTS hecks_backfill_progress (\
             target text PRIMARY KEY, cursor text, completed boolean NOT NULL DEFAULT false, \
             updated_at timestamptz NOT NULL DEFAULT now())").await?;

    let seq = sequence(domain);
    client.batch_execute(&format!("CREATE SEQUENCE IF NOT EXISTS {}", quote_ident(&seq))).await?;
    client
        .batch_execute(&format!(
            "CREATE TABLE IF NOT EXISTS {} (\
             ordinal bigint NOT NULL DEFAULT nextval('{seq}'), era int NOT NULL, \
             aggregate text NOT NULL, aggregate_id text NOT NULL, \
             operation text NOT NULL DEFAULT 'save', state jsonb, mirrors jsonb) \
             PARTITION BY LIST (era)",
            quote_ident(&journal)
        ))
        .await?;

    ensure_partition(client, domain, 1).await?;

    // Guarded the same way the RLS flags just below are: revoke writes
    // pg_class.relacl (and takes a lock) even when privileges are
    // already correct, and Ruby's own provisioning.rb found the hard
    // way that `has_table_privilege('public', ..., 'UPDATE')` can't
    // tell "never revoked" apart from "already revoked" (a brand-new
    // table already answers false to public-has-update by Postgres's
    // own default) -- `relacl IS NULL` is the one-time signal that
    // actually works.
    let relacl_null = client
        .query_opt(
            "SELECT relacl IS NULL FROM pg_class WHERE relname = $1 AND pg_table_is_visible(oid)",
            &[&journal],
        )
        .await?
        .map(|row| row.get::<_, bool>(0))
        .unwrap_or(true);
    if relacl_null {
        client.batch_execute(&format!("REVOKE UPDATE, DELETE ON {} FROM PUBLIC", quote_ident(&journal))).await?;
    }

    let current = client
        .query_opt(
            "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1 AND pg_table_is_visible(oid)",
            &[&journal],
        )
        .await?;
    let (rowsecurity, forcerowsecurity) = current.map(|row| (row.get::<_, bool>("relrowsecurity"), row.get::<_, bool>("relforcerowsecurity"))).unwrap_or((false, false));
    if !rowsecurity {
        client.batch_execute(&format!("ALTER TABLE {} ENABLE ROW LEVEL SECURITY", quote_ident(&journal))).await?;
    }
    if !forcerowsecurity {
        client.batch_execute(&format!("ALTER TABLE {} FORCE ROW LEVEL SECURITY", quote_ident(&journal))).await?;
    }

    install_transforms(client).await?;
    Ok(())
}

// ───────────────────────── resumable backfill ─────────────────────────

const CHUNK_SIZE: i64 = 5_000;

async fn backfill_progress<C: GenericClient>(client: &C, target: &str) -> anyhow::Result<(Option<String>, bool)> {
    let row = client.query_opt("SELECT cursor, completed FROM hecks_backfill_progress WHERE target = $1", &[&target]).await?;
    Ok(match row {
        None => (None, false),
        Some(row) => (row.get("cursor"), row.get("completed")),
    })
}

async fn upsert_backfill_progress<C: GenericClient>(client: &C, target: &str, cursor: Option<&str>, completed: bool) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_backfill_progress (target, cursor, completed, updated_at) VALUES ($1, $2, $3, now()) \
             ON CONFLICT (target) DO UPDATE SET cursor = EXCLUDED.cursor, completed = EXCLUDED.completed, updated_at = EXCLUDED.updated_at",
            &[&target, &cursor, &completed],
        )
        .await?;
    Ok(())
}

/// One chunk of `head_snapshot`'s own backfill — SAVEPOINT-nested,
/// since this always runs inside the mint transaction `mint_era`
/// already opened (never standalone; Ruby's own `nested_transaction`
/// branches on whether a transaction is already open, but this crate's
/// only caller always has one, so only the SAVEPOINT branch is needed).
async fn run_backfill_chunk<C: GenericClient>(client: &C, domain: &str, storage_name: &str, era: i32, target: &str) -> anyhow::Result<bool> {
    client.batch_execute("SAVEPOINT hecks_backfill_chunk").await?;
    let result: anyhow::Result<bool> = async {
        client.execute("SELECT pg_advisory_xact_lock(hashtext('hecks_field_cache:' || $1))", &[&target]).await?;
        let (cursor, completed) = backfill_progress(client, target).await?;
        if completed {
            return Ok(true);
        }

        let journal = journal_table(domain);
        let cursor_clause = cursor.as_deref().map(|c| format!(" AND aggregate_id > {}", text_literal(c))).unwrap_or_default();
        let source_sql = format!(
            "SELECT id, ordinal, state FROM (\
               SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, ordinal, operation, state \
               FROM {} WHERE era = {era} AND aggregate = {}{cursor_clause} \
               ORDER BY aggregate_id, ordinal DESC\
             ) latest WHERE operation = 'save' ORDER BY id LIMIT {CHUNK_SIZE}",
            quote_ident(&journal),
            text_literal(storage_name)
        );
        let rows = client.query(&source_sql, &[]).await?;
        if rows.is_empty() {
            upsert_backfill_progress(client, target, cursor.as_deref(), true).await?;
            return Ok(true);
        }

        let quoted_target = quote_ident(target);
        for row in &rows {
            let id: String = row.get("id");
            let ordinal: i64 = row.get("ordinal");
            let state: serde_json::Value = row.get("state");
            client
                .execute(
                    &format!(
                        "INSERT INTO {quoted_target} (id, ordinal, state) VALUES ($1, $2, $3) \
                         ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, state = EXCLUDED.state \
                         WHERE {quoted_target}.ordinal < EXCLUDED.ordinal"
                    ),
                    &[&id, &ordinal, &state],
                )
                .await?;
        }
        let done = (rows.len() as i64) < CHUNK_SIZE;
        let last_cursor: String = rows.last().unwrap().get("id");
        upsert_backfill_progress(client, target, Some(&last_cursor), done).await?;
        Ok(done)
    }
    .await;

    match &result {
        Ok(_) => client.batch_execute("RELEASE SAVEPOINT hecks_backfill_chunk").await?,
        Err(_) => client.batch_execute("ROLLBACK TO SAVEPOINT hecks_backfill_chunk").await?,
    }
    result
}

async fn backfill_head_snapshot<C: GenericClient>(client: &C, domain: &str, storage_name: &str, era: i32) -> anyhow::Result<()> {
    let target = head_snapshot(domain, storage_name, era);
    loop {
        if run_backfill_chunk(client, domain, storage_name, era, &target).await? {
            break;
        }
    }
    Ok(())
}

// ───────────────────────── head compilation ─────────────────────────

async fn table_exists<C: GenericClient>(client: &C, name: &str) -> anyhow::Result<bool> {
    let row = client
        .query_opt("SELECT 1 FROM pg_class WHERE relname = $1 AND relkind = 'r' AND pg_table_is_visible(oid)", &[&name])
        .await?;
    Ok(row.is_some())
}

/// Every aggregate's head snapshot for the era this boot adopted,
/// created if it isn't there — Ruby's own unconditional self-heal,
/// ported, and the fix for a real production outage.
///
/// `PostgresEra#initialize` does exactly this on every boot, for every
/// repository it builds, "regardless of era — belt-and-suspenders
/// self-healing ... against any boot-ordering surprise, at the cost of
/// one CREATE TABLE IF NOT EXISTS nobody pays for twice". This crate
/// only ever did it on the two paths that mint an era (`hold_first`,
/// `mint_era`); the third outcome, `BootDecision::UseExisting` — adopt
/// an era somebody else already minted — provisioned nothing.
///
/// Found live. embryonautfoundersapp's storehouse holds eras 1 and 2
/// for the domain, with era 2 minted by Ruby under the pre-ADR-0059
/// unqualified names; every domain-qualified head snapshot in it stops
/// at era 1. This host booted, matched era 2's label, adopted it, and
/// the first write it ever attempted died on
/// `relation "embryonaut_founders_app_state_style_head_snapshot_2"
/// does not exist` — surfaced to the caller as the bare string
/// "db error", because nothing on the way out said which statement or
/// which relation (see `journal::append_lineage_mutation`, now fixed
/// too). Every aggregate was in that position, not just the console's:
/// no write of any kind could have succeeded against that deployment.
///
/// No backfill here, deliberately. Backfilling is what minting an era
/// from its ancestor does; adopting an era someone else minted means
/// the history is already wherever that someone put it. This creates
/// the table and nothing else, exactly as Ruby's own
/// `ensure_head_snapshot!` does.
/// Its own transaction, explicitly. `create_head_snapshot` guards the
/// create-if-absent race with a `SAVEPOINT`, which Postgres only
/// accepts inside a transaction block — the minting callers are always
/// mid-transaction already, and this one, called straight off boot, is
/// not. Caught by this function's own test rather than in production,
/// which is the second time this change's real error message earned
/// itself: "SAVEPOINT can only be used in transaction blocks", named
/// and attached to the relation it was provisioning.
pub(crate) async fn adopt_head_snapshots<C: GenericClient>(
    client: &C,
    domain: &str,
    aggregates: &[Aggregate],
    era: i32,
) -> anyhow::Result<()> {
    client.batch_execute("BEGIN").await.context("opening a transaction to adopt head snapshots")?;
    let result: anyhow::Result<()> = async {
        for aggregate in aggregates {
            create_head_snapshot(client, domain, &aggregate.storage_name, era).await.with_context(|| {
                format!("provisioning {domain}'s {} head snapshot for era {era}", aggregate.storage_name)
            })?;
        }
        Ok(())
    }
    .await;
    match &result {
        Ok(_) => client.batch_execute("COMMIT").await?,
        Err(_) => client.batch_execute("ROLLBACK").await?,
    }
    result
}

async fn ensure_head_snapshot<C: GenericClient>(client: &C, domain: &str, storage_name: &str, era: i32) -> anyhow::Result<()> {
    create_head_snapshot(client, domain, storage_name, era).await?;
    backfill_head_snapshot(client, domain, storage_name, era).await
}

/// The create half, shared by minting and adopting.
///
/// The columns are Ruby's, not this crate's own shorter guess. They used
/// to be `(id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT
/// NULL)`, which a Ruby runtime cannot use: `head_compiler.rb` declares
/// `operation text NOT NULL DEFAULT 'save'` and a nullable `state`
/// because a DELETE upserts a tombstone here (`operation = 'delete'`,
/// `state` NULL) rather than removing the row, and every head view it
/// compiles filters `WHERE operation = 'save'`. A table this crate
/// created was therefore one Ruby could not compile a head over —
/// invisible while only one engine ever created them, and no longer so
/// now that `adopt_head_snapshots` above creates them on an ordinary
/// boot. Matching Ruby costs this crate nothing: its own INSERT names
/// `(id, ordinal, state)` and lets the default fill `operation` in,
/// which is what the real, live, Ruby-created tables already do.
async fn create_head_snapshot<C: GenericClient>(client: &C, domain: &str, storage_name: &str, era: i32) -> anyhow::Result<()> {
    let name = head_snapshot(domain, storage_name, era);
    if !table_exists(client, &name).await? {
        client.batch_execute("SAVEPOINT hecks_head_snapshot").await?;
        let result: anyhow::Result<()> = async {
            client.execute("SELECT pg_advisory_xact_lock(hashtext('hecks_head_snapshot:' || $1))", &[&name]).await?;
            if !table_exists(client, &name).await? {
                client
                    .batch_execute(&format!(
                        "CREATE TABLE {} (id text PRIMARY KEY, ordinal bigint NOT NULL, \
                         operation text NOT NULL DEFAULT 'save', state jsonb)",
                        quote_ident(&name)
                    ))
                    .await?;
            }
            Ok(())
        }
        .await;
        match &result {
            Ok(_) => client.batch_execute("RELEASE SAVEPOINT hecks_head_snapshot").await?,
            Err(_) => client.batch_execute("ROLLBACK TO SAVEPOINT hecks_head_snapshot").await?,
        }
        result?;
    }
    Ok(())
}

/// Which name/storage_name each aggregate carried at each era in the
/// chain, walked backward from the current (era N) name through every
/// edge's own `was:` — `head_compiler.rb`'s own `names_by_era`, pure
/// Ruby there, pure here too (no DB access).
fn names_by_era(current_name: &str, edges: &[&Edge]) -> (Vec<String>, Vec<String>) {
    let mut current = vec![String::new(); edges.len() + 1];
    current[edges.len()] = current_name.to_string();
    for index in (0..edges.len()).rev() {
        let declared = edges[index].for_aggregate(&current[index + 1]);
        current[index] = declared.and_then(|d| d.was.clone()).unwrap_or_else(|| current[index + 1].clone());
    }
    let storage = current.iter().map(|name| storage_shape_snake(name)).collect();
    (current, storage)
}

fn ancestor_tail_sql(domain: &str, era: i32, storage_names: &[String], watermarks: &std::collections::HashMap<i32, Option<i64>>) -> String {
    let journal = quote_ident(&journal_table(domain));
    (1..era)
        .map(|ancestor| {
            let cut = watermarks.get(&(ancestor + 1)).copied().flatten();
            let cut_clause = cut.map(|c| format!(" AND ordinal <= {c}")).unwrap_or_default();
            format!(
                "SELECT ordinal, era, aggregate, aggregate_id, operation, state FROM {journal} \
                 WHERE era = {ancestor} AND aggregate = {}{cut_clause}",
                text_literal(&storage_names[(ancestor - 1) as usize])
            )
        })
        .collect::<Vec<_>>()
        .join(" UNION ALL ")
}

fn latest_per_id(tail: &str) -> String {
    if tail.is_empty() {
        return tail.to_string();
    }
    format!("SELECT DISTINCT ON (aggregate_id) ordinal, era, aggregate, aggregate_id, operation, state FROM ({tail}) tail_entries ORDER BY aggregate_id, ordinal DESC")
}

/// The whole era chain as one `WITH` statement: the ancestor tail, then one
/// CTE per edge that applies that edge's compiled rules to the CTE before it.
///
/// **Each edge CTE is `MATERIALIZED`**. Postgres otherwise inlines a CTE that is
/// read once, and an edge's rules read `state` more than once (a backfill reads
/// its input three times, the era guard twice), so the planner copies the whole
/// previous edge's expression into every one of those reads. That doubles or
/// triples the expression tree at every edge: the six-edge chain of a real
/// deployment planned to about 70,000 sub-plans and ran for minutes (with JIT on,
/// which the expression's estimated cost switches on, for far longer), over a
/// journal of a few hundred rows. Materializing each edge evaluates it once per
/// row and makes the statement grow with the number of edges, not exponentially.
/// The rows are identical either way.
fn chain_sql(domain: &str, current_name: &str, era: i32, edges: &[&Edge], watermarks: &std::collections::HashMap<i32, Option<i64>>) -> String {
    chain_sql_with(domain, current_name, era, edges, watermarks, true)
}

fn chain_sql_with(
    domain: &str,
    current_name: &str,
    era: i32,
    edges: &[&Edge],
    watermarks: &std::collections::HashMap<i32, Option<i64>>,
    materialize_edges: bool,
) -> String {
    let fence = if materialize_edges { "MATERIALIZED " } else { "" };
    let (current_names, storage_names) = names_by_era(current_name, edges);
    let tail = latest_per_id(&ancestor_tail_sql(domain, era, &storage_names, watermarks));

    let chain: Vec<String> = edges
        .iter()
        .enumerate()
        .map(|(index, edge)| {
            let declared = edge.for_aggregate(&current_names[index + 1]);
            let expression = declared.map(|d| d.compiled_state_expression.clone()).unwrap_or_else(|| "state".to_string());
            let guard = format!("era <= {} AND operation = 'save'", index + 1);
            let id_column = match declared.filter(|d| d.compiled_id_expression.is_some()) {
                Some(d) => format!(
                    "CASE WHEN {guard} THEN {} ELSE aggregate_id END AS aggregate_id",
                    d.compiled_id_expression.as_deref().unwrap()
                ),
                None => "aggregate_id".to_string(),
            };
            let from = if index == 0 { "tail".to_string() } else { format!("edge_{index}") };
            format!(
                "edge_{} AS {fence}(SELECT ordinal, era, {id_column}, operation, CASE WHEN {guard} THEN {expression} ELSE state END AS state FROM {from})",
                index + 1
            )
        })
        .collect();

    format!("WITH tail AS {fence}({tail}),\n{}\nSELECT ordinal, aggregate_id, operation, state FROM edge_{}", chain.join(",\n"), edges.len())
}

/// `HeadCompiler#latest_of` — reduces any of the chain SQLs above (run
/// as a plain `SELECT`, never materialized) to one row per id: the
/// latest entry, and only if that latest entry was itself a save (a
/// latest DELETE means this id isn't live, so it's simply absent from
/// the result, matching Ruby's own `WHERE operation = 'save'` filter).
async fn latest_of<C: GenericClient>(client: &C, inner_sql: &str) -> anyhow::Result<std::collections::HashMap<String, Value>> {
    let sql = format!(
        "SELECT aggregate_id, state FROM (\
           SELECT DISTINCT ON (aggregate_id) aggregate_id, operation, state \
           FROM ({inner_sql}) chained ORDER BY aggregate_id, ordinal DESC\
         ) latest WHERE operation = 'save'"
    );
    let rows = client.query(&sql, &[]).await?;
    Ok(rows.into_iter().map(|row| (row.get::<_, String>("aggregate_id"), row.get::<_, Value>("state"))).collect())
}

/// The translated tail as it would stand in era `era`, latest entry per
/// id, saves only — `HeadCompiler#translated_latest`. What the audit
/// holds up against the reference transform as `after`.
async fn translated_latest<C: GenericClient>(
    client: &C,
    domain: &str,
    current_name: &str,
    era: i32,
    edges: &[&Edge],
    watermarks: &std::collections::HashMap<i32, Option<i64>>,
) -> anyhow::Result<std::collections::HashMap<String, Value>> {
    latest_of(client, &chain_sql(domain, current_name, era, edges, watermarks)).await
}

/// The UNtranslated ancestor tail, latest entry per id — `HeadCompiler#
/// ancestor_latest`, the "before" side of every per-rule preservation
/// check. `era` 1 (no ancestors at all) has an empty tail SQL string;
/// Ruby short-circuits that case rather than handing Postgres a `WITH
/// tail AS ()`, and this does too.
async fn ancestor_latest<C: GenericClient>(
    client: &C,
    domain: &str,
    current_name: &str,
    era: i32,
    edges: &[&Edge],
    watermarks: &std::collections::HashMap<i32, Option<i64>>,
) -> anyhow::Result<std::collections::HashMap<String, Value>> {
    let (_, storage_names) = names_by_era(current_name, edges);
    let tail = ancestor_tail_sql(domain, era, &storage_names, watermarks);
    if tail.is_empty() {
        return Ok(std::collections::HashMap::new());
    }
    latest_of(client, &format!("SELECT ordinal, era, aggregate_id, operation, state FROM ({tail}) tail_rows")).await
}

/// One aggregate's raw rule JSON within one raw edge (`ir.json`'s own
/// `translations` shape, `Exporter.translation_aggregate`'s exported
/// object) — `Edge#for_aggregate`'s raw-JSON twin, used where the
/// compiled `mint::Edge`/`EdgeAggregate` (SQL text only) isn't enough:
/// `reference_transform::translate` needs the declarative rules
/// (renames/moves/converts/drops/backfills) themselves.
fn raw_declared<'a>(raw_edges: &'a [Value], domain: &str, edge: &Edge, aggregate_name: &str) -> Option<&'a Value> {
    raw_edges
        .iter()
        .find(|candidate| {
            candidate.get("domain").and_then(Value::as_str) == Some(domain)
                && candidate.get("from").and_then(Value::as_str) == Some(edge.from.as_str())
                && candidate.get("to").and_then(Value::as_str) == Some(edge.to.as_str())
        })
        .and_then(|raw_edge| raw_edge.get("aggregates").and_then(Value::as_array))
        .and_then(|aggs| aggs.iter().find(|agg| agg.get("name").and_then(Value::as_str) == Some(aggregate_name)))
}

/// Layer 2 of the mint-time audit, for one aggregate — `Translation::
/// Audit::LayerTwo#layer_two!`, read directly: per-rule value
/// preservation, no leftover source keys, and id-set (or, across a
/// rekeying edge, record-count) conservation across the edge. Appends
/// every violation found to `violations` (collected, not raised
/// immediately — matching Ruby's own `violations << ...` shape, so one
/// mint reports everything wrong at once); a `reference_transform::
/// translate` failure (a `Runtime::WiringError`-equivalent hard abort,
/// e.g. an unmapped convert value) propagates immediately via `?`
/// instead, exactly like Ruby's own unrescued raise does.
///
/// `declared` is the raw rule JSON for this aggregate within the one
/// edge actually being minted this boot (`chain.last()`) — never the
/// whole chain; a multi-hop drift's earlier edges already minted (and
/// were already audited) on some prior boot.
async fn audit_layer_two<C: GenericClient>(
    client: &C,
    domain: &str,
    aggregate: &Aggregate,
    ordinal: i32,
    edges: &[&Edge],
    raw_edges: &[Value],
    watermarks: &std::collections::HashMap<i32, Option<i64>>,
    after: &std::collections::HashMap<String, Value>,
    violations: &mut Vec<String>,
) -> anyhow::Result<()> {
    let before = if edges.len() > 1 {
        translated_latest(client, domain, &aggregate.name, ordinal, &edges[..edges.len() - 1], watermarks).await?
    } else {
        ancestor_latest(client, domain, &aggregate.name, ordinal, edges, watermarks).await?
    };

    let last_edge = edges.last().expect("mint always audits at least one edge");
    let declared = raw_declared(raw_edges, domain, last_edge, &aggregate.name);
    let rekeyed = declared.map(|d| !d.get("rekeys").and_then(Value::as_array).map(Vec::is_empty).unwrap_or(true)).unwrap_or(false);

    if rekeyed {
        if before.len() != after.len() {
            violations.push(format!(
                "{}: the record count changed across a rekeying edge ({} before, {} after) — a rekey must not \
                 collide two distinct ids onto one, or drop one",
                aggregate.name,
                before.len(),
                after.len()
            ));
        }
    } else {
        let mut lost: Vec<&String> = before.keys().filter(|id| !after.contains_key(*id)).collect();
        let mut gained: Vec<&String> = after.keys().filter(|id| !before.contains_key(*id)).collect();
        if !lost.is_empty() || !gained.is_empty() {
            lost.sort();
            gained.sort();
            violations.push(format!(
                "{}: the id set changed across the edge (lost {:?}, gained {:?})",
                aggregate.name, lost, gained
            ));
        }
    }

    let Some(declared) = declared else { return Ok(()) };
    if rekeyed {
        return Ok(());
    }

    let compute_tops: std::collections::HashSet<String> = declared
        .get("computes")
        .and_then(Value::as_array)
        .map(|computes| {
            computes
                .iter()
                .flat_map(|c| [c.get("from"), c.get("to")])
                .flatten()
                .filter_map(Value::as_str)
                .map(|path| path.split('.').next().unwrap_or(path).to_string())
                .collect()
        })
        .unwrap_or_default();

    for (id, state) in &before {
        let Some(actual_after) = after.get(id) else { continue };
        let expected = reference_transform::translate(declared, state)?;
        let expected = strip_keys(&expected, &compute_tops);
        let actual = strip_keys(actual_after, &compute_tops);
        if expected != actual {
            let mut diverged: Vec<String> = expected
                .as_object()
                .into_iter()
                .flat_map(|o| o.keys())
                .chain(actual.as_object().into_iter().flat_map(|o| o.keys()))
                .filter(|key| expected.get(key.as_str()) != actual.get(key.as_str()))
                .cloned()
                .collect();
            diverged.sort();
            diverged.dedup();
            violations.push(format!("{}#{id}: the translated state diverges from the reference transform at {}", aggregate.name, diverged.join(", ")));
        }
    }
    Ok(())
}

fn strip_keys(state: &Value, keys: &std::collections::HashSet<String>) -> Value {
    match state {
        Value::Object(map) => Value::Object(map.iter().filter(|(k, _)| !keys.contains(*k)).map(|(k, v)| (k.clone(), v.clone())).collect()),
        other => other.clone(),
    }
}

/// The whole mint-time audit, over every lineage-capable aggregate —
/// `CoverageCheck#audit!`/`Translation::Audit.check`, read directly.
/// Runs before anything is minted (over the live compiled chain, plain
/// `SELECT`s, never a persisted matview), so a refusal leaves no
/// half-born era: the same ordering `Minter#mint!` holds itself to
/// (`audit!` before `lineage.mint_era!`). Layer 1 (structural:
/// `reference_validate`) and Layer 2 (`reference_transform`, per-rule
/// preservation) both run here, over every aggregate — Layer 1's own
/// documented gap (custom invariant predicate text, not yet evaluated)
/// is named in `reference_validate`'s own header, not silently absent.
///
/// `ir` is the whole `ir.json` `Value` — Layer 1 looks up each
/// aggregate's own node from `ir.get("aggregates")` by name.
pub async fn audit_before_mint<C: GenericClient>(
    client: &C,
    domain: &str,
    ir: &Value,
    aggregates: &[Aggregate],
    ordinal: i32,
    edges: &[&Edge],
    raw_edges: &[Value],
    watermarks: &std::collections::HashMap<i32, Option<i64>>,
) -> anyhow::Result<()> {
    let ir_aggregates: std::collections::HashMap<&str, &Value> = ir
        .get("aggregates")
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(|agg| agg.get("name").and_then(Value::as_str).map(|n| (n, agg))).collect())
        .unwrap_or_default();

    let mut violations = Vec::new();
    for aggregate in aggregates {
        let phase = crate::log::phase_with("audit_aggregate", serde_json::json!({ "aggregate": &aggregate.storage_name }));
        let after = translated_latest(client, domain, &aggregate.name, ordinal, edges, watermarks).await?;

        // Layer 1 — structural (types/patterns/admits/lifecycle) — over
        // every record `after` actually holds, matching Ruby's own
        // `layer_one!(violations, aggregate, after)` exactly.
        if let Some(aggregate_ir) = ir_aggregates.get(aggregate.name.as_str()) {
            for (id, state) in &after {
                violations.extend(reference_validate::validate(aggregate_ir, id, state));
            }
        }

        // Layer 2 — per-rule value preservation against the reference
        // transform, id-set/count conservation.
        audit_layer_two(client, domain, aggregate, ordinal, edges, raw_edges, watermarks, &after, &mut violations).await?;
        phase.end_with(serde_json::json!({ "records": after.len() }));
    }
    if violations.is_empty() {
        return Ok(());
    }
    anyhow::bail!("cannot mint era {ordinal} of {domain}: the audit refused —\n  - {}", violations.join("\n  - "));
}

/// `compile_head!` — one aggregate's matview + head-snapshot + head
/// view, for one era, over the full (never layered) chain.
async fn compile_head<C: GenericClient>(
    client: &C,
    domain: &str,
    aggregate: &Aggregate,
    era: i32,
    label: &str,
    edges: &[&Edge],
    watermarks: &std::collections::HashMap<i32, Option<i64>>,
) -> anyhow::Result<()> {
    let storage_name = &aggregate.storage_name;
    let view = matview(domain, storage_name, era, label);
    let body = chain_sql(domain, &aggregate.name, era, edges, watermarks);

    client.batch_execute(&format!("CREATE MATERIALIZED VIEW {} AS\n{body}", quote_ident(&view))).await?;
    client
        .batch_execute(&format!(
            "CREATE INDEX IF NOT EXISTS {} ON {} (aggregate_id, ordinal DESC)",
            quote_ident(&format!("{view}_reduce_idx")),
            quote_ident(&view)
        ))
        .await?;

    ensure_head_snapshot(client, domain, storage_name, era).await?;

    client.batch_execute(&format!("DROP VIEW IF EXISTS {}", quote_ident(&head_view(domain, storage_name)))).await?;
    client
        .batch_execute(&format!(
            "CREATE VIEW {} AS \
             SELECT id, state FROM (\
               SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state FROM (\
                 SELECT ordinal, aggregate_id, operation, state FROM {} \
                 UNION ALL \
                 SELECT ordinal, id AS aggregate_id, 'save' AS operation, state FROM {}\
               ) merged ORDER BY aggregate_id, ordinal DESC\
             ) latest WHERE operation = 'save'",
            quote_ident(&head_view(domain, storage_name)),
            quote_ident(&view),
            quote_ident(&head_snapshot(domain, storage_name, era))
        ))
        .await?;
    Ok(())
}

// ───────────────────────── mint transaction ─────────────────────────

/// `hold_first!`, eagerly named (see this file's own header). Fresh
/// domain, era 1, no edge — always safe, never needs the approval gate
/// (a first hold has nothing to migrate from). Also does what
/// `EraResolver#check!`'s hold-first path does as a separate step
/// right after Ruby's own `hold_first!` — `ensure_first_head!` per
/// aggregate — folded in here since this function's whole job is
/// "make era 1 ready to write into", and a `journal::
/// append_lineage_mutation` call needs `<storage>_head_snapshot_1` to
/// already exist.
pub async fn hold_first<C: GenericClient>(client: &C, domain: &str, held_text: &str, ir: &Value, aggregates: &[Aggregate], role: Option<&str>) -> anyhow::Result<()> {
    ensure_base(client, domain).await?;

    // Own transaction — `ensure_first_head`'s own `ensure_head_snapshot`
    // (and its backfill loop, a no-op for a brand-new era with nothing
    // yet to backfill, but still SAVEPOINT-shaped) needs one open.
    // Ruby's own `hold_first!` doesn't wrap itself this tightly (each
    // statement autocommits on its own), safe here as a strictly
    // safer simplification, not a behavior it depends on staying loose.
    client.batch_execute("BEGIN").await?;
    let result = hold_first_body(client, domain, held_text, ir, aggregates, role).await;
    match &result {
        Ok(_) => client.batch_execute("COMMIT").await?,
        Err(_) => {
            let _ = client.batch_execute("ROLLBACK").await;
        }
    }
    result
}

async fn hold_first_body<C: GenericClient>(client: &C, domain: &str, held_text: &str, ir: &Value, aggregates: &[Aggregate], role: Option<&str>) -> anyhow::Result<()> {
    let hash = storage_shape::mint_hash(ir);
    let label = storage_shape::mint_label(ir);
    let digest = format!("{:x}", Sha256::digest(held_text.as_bytes()));

    client
        .execute(
            "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, canon_form) \
             VALUES ($1, 1, $2, $3, $4, 0, $5, $6) ON CONFLICT DO NOTHING",
            &[&domain, &hash, &label, &held_text, &digest, &storage_shape::FORM_VERSION],
        )
        .await?;
    archive_text(client, domain, 1, held_text, &digest).await?;
    for aggregate in aggregates {
        ensure_first_head(client, domain, &aggregate.storage_name).await?;
    }
    advance_era(client, domain, 1).await?;
    if let Some(role) = role {
        grant_role(client, domain, role, &[], None).await?;
    }
    Ok(())
}

/// `ensure_first_head!` — era 1's head is a plain view over its own
/// (immediately-created) snapshot table, no chain to compile, no
/// translation possible from nothing.
async fn ensure_first_head<C: GenericClient>(client: &C, domain: &str, storage_name: &str) -> anyhow::Result<()> {
    ensure_head_snapshot(client, domain, storage_name, 1).await?;
    client
        .batch_execute(&format!(
            "CREATE OR REPLACE VIEW {} AS SELECT id, state FROM {}",
            quote_ident(&head_view(domain, storage_name)),
            quote_ident(&head_snapshot(domain, storage_name, 1))
        ))
        .await?;
    Ok(())
}

async fn archive_text<C: GenericClient>(client: &C, domain: &str, ordinal: i32, text: &str, digest: &str) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_era_texts (domain, ordinal, digest, held_text) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
            &[&domain, &ordinal, &digest, &text],
        )
        .await?;
    Ok(())
}

pub(crate) async fn advance_era<C: GenericClient>(client: &C, domain: &str, ordinal: i32) -> anyhow::Result<()> {
    let journal = quote_ident(&journal_table(domain));
    client.batch_execute(&format!("DROP POLICY IF EXISTS hecks_current_era ON {journal}")).await?;
    client
        .batch_execute(&format!("CREATE POLICY hecks_current_era ON {journal} FOR INSERT TO PUBLIC WITH CHECK (era = {ordinal})"))
        .await?;
    client.batch_execute(&format!("DROP POLICY IF EXISTS hecks_read_all ON {journal}")).await?;
    client.batch_execute(&format!("CREATE POLICY hecks_read_all ON {journal} FOR SELECT TO PUBLIC USING (true)")).await?;
    Ok(())
}

async fn grant_role<C: GenericClient>(client: &C, domain: &str, role: &str, aggregates: &[Aggregate], era: Option<i32>) -> anyhow::Result<()> {
    let journal = journal_table(domain);
    if !provisioner(client, &journal).await? {
        return Ok(());
    }
    let quoted_role = quote_ident(role);
    client.batch_execute(&format!("GRANT INSERT, SELECT ON {} TO {quoted_role}", quote_ident(&journal))).await?;
    client.batch_execute(&format!("GRANT USAGE ON SEQUENCE {} TO {quoted_role}", quote_ident(&sequence(domain)))).await?;
    let Some(era) = era else { return Ok(()) };
    for aggregate in aggregates {
        let storage_name = &aggregate.storage_name;
        client
            .batch_execute(&format!(
                "GRANT SELECT, INSERT, UPDATE, DELETE ON {} TO {quoted_role}",
                quote_ident(&head_snapshot(domain, storage_name, era))
            ))
            .await?;
        let view = head_view(domain, storage_name);
        if table_or_view_exists(client, &view).await? {
            client.batch_execute(&format!("GRANT SELECT ON {} TO {quoted_role}", quote_ident(&view))).await?;
        }
    }
    Ok(())
}

async fn table_or_view_exists<C: GenericClient>(client: &C, name: &str) -> anyhow::Result<bool> {
    let row = client
        .query_opt("SELECT 1 FROM pg_class WHERE relname = $1 AND relkind IN ('v', 'm') AND pg_table_is_visible(oid)", &[&name])
        .await?;
    Ok(row.is_some())
}

/// `mint_era!` — the one transaction that makes era `ordinal` real:
/// advisory lock, idempotency check, watermark capture, the
/// `hecks_eras` row, every aggregate's compiled head, grants, the RLS
/// fence flip. Approval-gate checking (compute/rekey edges) is the
/// caller's job (`crate::main`'s boot gate) — this function mints once
/// asked to, the same separation `Minter#mint!` (checks, then calls
/// `Lineage#mint_era!`) already draws in Ruby.
#[allow(clippy::too_many_arguments)]
pub async fn mint_era<C: GenericClient>(
    client: &C,
    domain: &str,
    ordinal: i32,
    hash: &str,
    label: &str,
    held_text: &str,
    aggregates: &[Aggregate],
    edges: &[&Edge],
    role: Option<&str>,
    lifecycle_defaults: &[LifecycleDefault],
) -> anyhow::Result<()> {
    client.batch_execute("BEGIN").await?;
    let result = mint_era_body(client, domain, ordinal, hash, label, held_text, aggregates, edges, role, lifecycle_defaults).await;
    match &result {
        Ok(_) => {
            let phase = crate::log::phase_with("mint_commit", serde_json::json!({ "era": ordinal }));
            client.batch_execute("COMMIT").await?;
            phase.end();
        }
        Err(_) => {
            let _ = client.batch_execute("ROLLBACK").await;
        }
    }
    result
}

#[allow(clippy::too_many_arguments)]
async fn mint_era_body<C: GenericClient>(
    client: &C,
    domain: &str,
    ordinal: i32,
    hash: &str,
    label: &str,
    held_text: &str,
    aggregates: &[Aggregate],
    edges: &[&Edge],
    role: Option<&str>,
    lifecycle_defaults: &[LifecycleDefault],
) -> anyhow::Result<()> {
    client.batch_execute("SET LOCAL lock_timeout = '10s'").await?;
    client
        .execute(&format!("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:' || {}))", text_literal(domain)), &[])
        .await?;

    let already_minted = client.query_opt("SELECT 1 FROM hecks_eras WHERE domain = $1 AND ordinal = $2", &[&domain, &ordinal]).await?;
    if already_minted.is_some() {
        anyhow::bail!("era {ordinal} of {domain} is already minted — nothing to do");
    }

    let watermark = crate::journal::last_ordinal(client, domain).await?;
    let digest = format!("{:x}", Sha256::digest(held_text.as_bytes()));
    client
        .execute(
            "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, canon_form) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
            &[&domain, &ordinal, &hash, &label, &held_text, &watermark, &digest, &storage_shape::FORM_VERSION],
        )
        .await?;
    archive_text(client, domain, ordinal, held_text, &digest).await?;
    ensure_partition(client, domain, ordinal).await?;

    // Every held era's own watermark, for `ancestor_tail_sql`'s cut —
    // includes the row just inserted above (its own watermark is what
    // bounds era `ordinal - 1`'s own tail read, same as every other
    // ancestor).
    let held = crate::journal::held_eras(client, domain).await?;
    let watermarks: std::collections::HashMap<i32, Option<i64>> = held.iter().map(|era| (era.ordinal, era.watermark)).collect();

    for aggregate in aggregates {
        let phase = crate::log::phase_with("compile_head", serde_json::json!({ "aggregate": &aggregate.storage_name, "era": ordinal }));
        compile_head(client, domain, aggregate, ordinal, label, edges, &watermarks).await?;
        phase.end();
    }

    // Same transaction as the era row and the fence flip: a boot that sees
    // the new era also sees a snapshot the new shape can read.
    let phase = crate::log::phase_with("snapshot_fill", serde_json::json!({ "era": ordinal }));
    let filled = fill_snapshot_lifecycle_defaults(client, domain, lifecycle_defaults).await?;
    phase.end_with(serde_json::json!({ "instances_filled": filled }));

    if let Some(role) = role {
        grant_role(client, domain, role, aggregates, Some(ordinal)).await?;
    }
    advance_era(client, domain, ordinal).await?;
    Ok(())
}

// ───────────────────── snapshot seed fill ─────────────────────

/// A lifecycle field an aggregate's instances must carry, and the state a
/// new instance starts in. One per aggregate that declares a `lifecycle`
/// in `ir.json`.
///
/// `key_prefix` is the seed's own key shape up to the id (`"Domain::Aggregate#"`),
/// the same one the kernel's `instances()` dump writes.
#[derive(Debug, Clone, PartialEq)]
pub struct LifecycleDefault {
    pub key_prefix: String,
    pub field: String,
    pub default: String,
}

/// Every aggregate's lifecycle field and default, read out of `ir.json`'s
/// `aggregates[].lifecycle`. An aggregate with no lifecycle (or no string
/// default) contributes nothing.
pub fn lifecycle_defaults(ir: &Value) -> Vec<LifecycleDefault> {
    let domain_name = ir.get("name").and_then(Value::as_str).unwrap_or_default();
    ir.get("aggregates")
        .and_then(Value::as_array)
        .map(|aggregates| {
            aggregates
                .iter()
                .filter_map(|aggregate| {
                    let name = aggregate.get("name")?.as_str()?;
                    let lifecycle = aggregate.get("lifecycle")?;
                    let field = lifecycle.get("field")?.as_str()?;
                    let default = lifecycle.get("default")?.as_str()?;
                    Some(LifecycleDefault {
                        key_prefix: format!("{domain_name}::{name}#"),
                        field: field.to_string(),
                        default: default.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Gives every seeded instance that lacks its aggregate's lifecycle field
/// that field's default, in place; returns how many instances changed.
///
/// The kernel rebuilds each aggregate from the seed with a `from_json` that
/// requires every lifecycle field, so a snapshot written before an aggregate
/// gained one would refuse to load. An instance that already carries the
/// field (even in a state other than the default) is left alone, as is any
/// aggregate not named in `defaults`, so running this twice changes nothing
/// the second time.
pub fn fill_lifecycle_defaults(seed: &mut Value, defaults: &[LifecycleDefault]) -> usize {
    let Some(instances) = seed.as_object_mut() else { return 0 };
    let mut changed = 0;
    for (key, instance) in instances.iter_mut() {
        let Some(default) = defaults.iter().find(|d| key.starts_with(&d.key_prefix)) else { continue };
        let Some(fields) = instance.as_object_mut() else { continue };
        if fields.get(&default.field).is_none_or(Value::is_null) {
            fields.insert(default.field.clone(), Value::String(default.default.clone()));
            changed += 1;
        }
    }
    changed
}

/// Fills the stored kernel snapshot's instances with `defaults`, inside the
/// caller's transaction.
///
/// The snapshot is what every dispatch and read seeds the kernel from. The
/// era's own translation only rewrites the head views, so without this a
/// snapshot written under the old shape stays without the new field and the
/// first request after the mint dies with `invalid seed`. Takes the same
/// advisory lock a dispatch holds for its whole transaction, so an in-flight
/// dispatch finishes (and saves its snapshot) before this reads it. A
/// database with no snapshot table or no snapshot row has nothing to fill.
async fn fill_snapshot_lifecycle_defaults<C: GenericClient>(client: &C, domain: &str, defaults: &[LifecycleDefault]) -> anyhow::Result<usize> {
    if defaults.is_empty() {
        return Ok(0);
    }
    let table_exists: bool = client.query_one("SELECT to_regclass('hecks_lambda_snapshot') IS NOT NULL", &[]).await?.get(0);
    if !table_exists {
        return Ok(0);
    }
    client.execute("SELECT pg_advisory_xact_lock(hashtext('hecks_lambda_journal.' || $1::text))", &[&domain]).await?;
    let Some(row) = client.query_opt("SELECT seed FROM hecks_lambda_snapshot FOR UPDATE", &[]).await? else { return Ok(0) };
    let mut seed: Value = row.get(0);
    let changed = fill_lifecycle_defaults(&mut seed, defaults);
    if changed > 0 {
        client.execute("UPDATE hecks_lambda_snapshot SET seed = $1", &[&seed]).await.context("filling lifecycle defaults into the snapshot")?;
    }
    Ok(changed)
}

#[cfg(test)]
mod tests {

    /// A throwaway database of its own — `mint.rs` compiles into
    /// `bin/mint_harness` as well as the main binary, and that one has
    /// no `dispatch` module to borrow a helper from.
    async fn own_scratch_db(name: &str) -> tokio_postgres::Client {
        let (admin, connection) =
            tokio_postgres::connect("host=localhost dbname=postgres", NoTls).await.expect("connect as admin");
        tokio::spawn(async move {
            let _ = connection.await;
        });
        let _ = admin.batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)")).await;
        admin.batch_execute(&format!("CREATE DATABASE {name}")).await.expect("create scratch db");
        let (client, connection) = tokio_postgres::connect(&format!("host=localhost dbname={name}"), NoTls)
            .await
            .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = connection.await;
        });
        client
    }

    /// **The real outage, reproduced**. embryonautfoundersapp's storehouse
    /// holds an era 2 that Ruby minted, so every domain-qualified head
    /// snapshot in it stops at era 1. This host matched era 2's label,
    /// adopted it, and its first write died on `relation
    /// "embryonaut_founders_app_state_style_head_snapshot_2" does not
    /// exist`.
    #[tokio::test]
    async fn adopting_an_era_someone_else_minted_provisions_the_head_snapshots_it_is_missing() {
        let guard = own_scratch_db("hecks_host_adopt_head_snapshots").await;
        // Era 1's snapshot only — exactly the shape a Ruby-minted era 2
        // leaves behind for this crate's own domain-qualified naming.
        super::adopt_head_snapshots(
            &guard,
            "EmbryonautFoundersApp",
            &[super::Aggregate { name: "StateStyle".to_string(), storage_name: "state_style".to_string() }],
            1,
        )
        .await
        .expect("era 1 exists, as Ruby left it");

        let missing = super::head_snapshot("EmbryonautFoundersApp", "state_style", 2);
        assert!(!super::table_exists(&guard, &missing).await.expect("a lookup"), "era 2 starts absent");

        let aggregates =
            vec![super::Aggregate { name: "StateStyle".to_string(), storage_name: "state_style".to_string() }];
        super::adopt_head_snapshots(&guard, "EmbryonautFoundersApp", &aggregates, 2).await.expect("adopts");

        assert!(super::table_exists(&guard, &missing).await.expect("a lookup"), "era 2 is provisioned now");

        // Idempotent — every boot runs it, the same way Ruby's does.
        super::adopt_head_snapshots(&guard, "EmbryonautFoundersApp", &aggregates, 2).await.expect("adopts again");
    }

    /// The columns are Ruby's, so a table this crate creates is one a
    /// Ruby runtime can still compile a head view over (`WHERE operation
    /// = 'save'`) and still write a delete tombstone into (`state` NULL).
    #[tokio::test]
    async fn a_head_snapshot_this_crate_creates_carries_rubys_own_columns() {
        let guard = own_scratch_db("hecks_host_head_snapshot_columns").await;
        let aggregates = vec![super::Aggregate { name: "Widget".to_string(), storage_name: "widget".to_string() }];
        super::adopt_head_snapshots(&guard, "Fixtures", &aggregates, 1).await.expect("adopts");

        let name = super::head_snapshot("Fixtures", "widget", 1);
        let rows = guard
            .query(
                "SELECT column_name, is_nullable, column_default FROM information_schema.columns \
                 WHERE table_name = $1 ORDER BY ordinal_position",
                &[&name],
            )
            .await
            .expect("columns");
        let columns: Vec<String> = rows.iter().map(|r| r.get::<_, String>(0)).collect();
        assert_eq!(columns, vec!["id", "ordinal", "operation", "state"]);

        let operation = rows.iter().find(|r| r.get::<_, String>(0) == "operation").expect("operation");
        assert_eq!(operation.get::<_, String>(1), "NO", "operation is NOT NULL");
        assert!(operation.get::<_, Option<String>>(2).unwrap_or_default().contains("save"), "defaults to 'save'");

        let state = rows.iter().find(|r| r.get::<_, String>(0) == "state").expect("state");
        assert_eq!(state.get::<_, String>(1), "YES", "state is nullable, for a delete tombstone");
    }
    use super::*;
    use crate::journal;
    use tokio_postgres::NoTls;

    fn rule(name: &str, was: Option<&str>, expression: &str) -> EdgeAggregate {
        EdgeAggregate { name: name.to_string(), was: was.map(str::to_string), has_compute_or_rekey: false, compiled_state_expression: expression.to_string(), compiled_id_expression: None }
    }

    // A real, multi-hop chain: era1 "Pizza" -> era2 rename to "Order"
    // (a rename, was: "Pizza") -> era3 an attribute-only edge on
    // "Order" (no was:). `names_by_era` has to walk this backward
    // correctly for chain_sql's per-ancestor storage-name filter to
    // read the right journal rows at each era — the one piece of
    // compile_head!'s own logic no single-edge test can exercise.
    #[test]
    fn names_by_era_walks_a_multi_hop_rename_chain_backward_correctly() {
        let edge_1_to_2 = Edge { from: "aaa".to_string(), to: "bbb".to_string(), aggregates: vec![rule("Order", Some("Pizza"), "hecks_tr_rename(state, 'x', 'y')")] };
        let edge_2_to_3 = Edge { from: "bbb".to_string(), to: "ccc".to_string(), aggregates: vec![rule("Order", None, "hecks_tr_rename(state, 'y', 'z')")] };
        let edges: Vec<&Edge> = vec![&edge_1_to_2, &edge_2_to_3];

        let (current, storage) = names_by_era("Order", &edges);

        // era 1 (index 0): the old name, "Pizza" -- read from edge_1_to_2's
        // own `was:`. era 2 (index 1) and era 3 (index 2): "Order",
        // unchanged since nothing renamed it again.
        assert_eq!(current, vec!["Pizza".to_string(), "Order".to_string(), "Order".to_string()]);
        assert_eq!(storage, vec!["pizza".to_string(), "order".to_string(), "order".to_string()]);
    }

    #[test]
    fn edge_chain_finds_the_real_path_and_refuses_a_broken_one() {
        let edge = Edge { from: "aaa".to_string(), to: "bbb".to_string(), aggregates: vec![] };
        let edges = vec![edge.clone()];

        let found = edge_chain(&edges, &["aaa".to_string(), "bbb".to_string()]).expect("a real edge connects aaa to bbb");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].to, "bbb");

        let broken = edge_chain(&edges, &["aaa".to_string(), "zzz".to_string()]);
        assert!(broken.is_err(), "no edge leads aaa to zzz -- must refuse, not silently skip");
    }

    fn held(ordinal: i32, label: Option<&str>) -> journal::HeldEra {
        journal::HeldEra { ordinal, hash: label.map(|_| "irrelevant".to_string()), label: label.map(str::to_string), held_text: String::new(), watermark: None }
    }

    // The four branches `main.rs`'s boot gate calls into, rather than
    // inlining directly — pure, so each one is provable without a real
    // Postgres.
    #[test]
    fn decide_boot_action_covers_all_four_branches() {
        // No held eras at all -- brand new domain, hold era 1.
        assert_eq!(decide_boot_action(&[], "abc123"), BootDecision::HoldFirst);

        // A held era already names this exact shape -- boot at it,
        // even if it's not the latest one (an operator could roll back
        // to an older binary whose shape a prior era already covers).
        let already_named = vec![held(1, Some("aaa111")), held(2, Some("bbb222"))];
        assert_eq!(decide_boot_action(&already_named, "aaa111"), BootDecision::UseExisting { ordinal: 1 });
        assert_eq!(decide_boot_action(&already_named, "bbb222"), BootDecision::UseExisting { ordinal: 2 });

        // Held, but the latest doesn't match this binary's shape -- mint
        // the next ordinal from the latest's own label.
        let drifted = vec![held(1, Some("aaa111"))];
        assert_eq!(
            decide_boot_action(&drifted, "ccc333"),
            BootDecision::Mint { ordinal: 2, from_ordinal: 1, from_label: "aaa111".to_string() }
        );

        // The latest held era has no label yet (Ruby minted it, never
        // named it) -- refuse rather than guess whether it matches.
        let unnamed = vec![held(1, Some("aaa111")), held(2, None)];
        assert_eq!(decide_boot_action(&unnamed, "ccc333"), BootDecision::LatestUnnamed { ordinal: 2 });
    }

    // The end-to-end proof ADR-0030-in-progress exists for: Rust mints
    // both eras itself, real Postgres, zero Ruby process anywhere in
    // this test — `hold_first` (era 1), real writes through the
    // already-proven generic `journal::append_lineage_mutation`, then
    // `mint_era` (era 2) via a hand-built rename edge, then a real read
    // back through `journal::read_lineage_head_all` proving the
    // translation actually ran. Every prior lineage test in this crate
    // (journal.rs's own) proves Rust reads/writes eras Ruby minted —
    // this is the one that proves Rust needs no Ruby to mint at all.
    #[tokio::test]
    async fn rust_mints_both_eras_itself_writes_and_reads_back_the_translated_data() {
        let db = "rust_host_self_mint_test";
        let owner = "rust_host_self_mint_owner";

        let admin = tokio_postgres::connect("host=localhost dbname=postgres", NoTls).await;
        let (admin_client, admin_connection) = admin.expect("connect to postgres as admin");
        tokio::spawn(async move {
            let _ = admin_connection.await;
        });
        let _ = admin_client.batch_execute(&format!("DROP DATABASE IF EXISTS {db} WITH (FORCE)")).await;
        admin_client.batch_execute(&format!("CREATE DATABASE {db}")).await.expect("create scratch db");
        let _ = admin_client.batch_execute(&format!("DROP ROLE IF EXISTS {owner}")).await;
        admin_client.batch_execute(&format!("CREATE ROLE {owner} LOGIN")).await.expect("create owner role");
        admin_client.batch_execute(&format!("GRANT CONNECT ON DATABASE {db} TO {owner}")).await.expect("grant connect");

        let grant = tokio_postgres::connect(&format!("host=localhost dbname={db}"), NoTls).await;
        let (grant_client, grant_connection) = grant.expect("connect to scratch db as superuser to grant schema rights");
        tokio::spawn(async move {
            let _ = grant_connection.await;
        });
        grant_client.batch_execute(&format!("GRANT USAGE, CREATE ON SCHEMA public TO {owner}")).await.expect("grant schema rights");
        grant_client.batch_execute(&format!("ALTER DATABASE {db} OWNER TO {owner}")).await.expect("make owner the db owner");

        let (client, connection) = tokio_postgres::connect(&format!("host=localhost dbname={db} user={owner}"), NoTls).await.expect("connect as owner");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        let domain = "SelfMint";

        fn shape(attribute_name: &str) -> Value {
            serde_json::json!({
                "name": "SelfMint",
                "aggregates": [{
                    "name": "Widget",
                    "identified_by": ["kind"],
                    "attributes": [
                        {"name": attribute_name, "type": "Money", "list": false},
                        {"name": "kind", "type": "Kind", "list": false}
                    ],
                    "value_objects": [
                        {"name": "Money", "attributes": [{"name": "cents", "type": "Integer", "list": false}]},
                        {"name": "Kind", "attributes": [{"name": "label", "type": "String", "list": false}]}
                    ],
                    "entities": []
                }]
            })
        }
        let v1_ir = shape("cost");
        let v2_ir = shape("amount");

        // ── era 1: Rust mints it, no Ruby, no edge needed ──
        let aggregate = Aggregate { name: "Widget".to_string(), storage_name: "widget".to_string() };
        hold_first(&client, domain, "v1 source text (opaque to this crate)", &v1_ir, &[aggregate.clone()], None).await.expect("hold_first");

        let config = journal::LineageConfig { domain: domain.to_string(), era: Some(1), mirrored: None };
        journal::append_lineage_mutation(
            &client,
            &config,
            &journal::Mutation { aggregate: "Widget", id: "w1", operation: "save", state: &serde_json::json!({"cost": {"cents": 100}, "kind": {"label": "w1"}}) },
        )
        .await
        .expect("write w1 under era 1");
        journal::append_lineage_mutation(
            &client,
            &config,
            &journal::Mutation { aggregate: "Widget", id: "w2", operation: "save", state: &serde_json::json!({"cost": {"cents": 200}, "kind": {"label": "w2"}}) },
        )
        .await
        .expect("write w2 under era 1");

        // ── era 2: Rust mints it too, via a hand-built rename edge — the
        // same shape Exporter.translation_aggregate would export, just
        // constructed directly here rather than read from a real ir.json,
        // since this test's whole point is proving the mint mechanics,
        // not the build-time export pipeline (that's storage_shape.rs's
        // own, separately-proven job). ──
        let from_label = storage_shape::mint_label(&v1_ir);
        let to_label = storage_shape::mint_label(&v2_ir);
        let edge = Edge {
            from: from_label,
            to: to_label.clone(),
            aggregates: vec![EdgeAggregate {
                name: "Widget".to_string(),
                was: None,
                has_compute_or_rekey: false,
                compiled_state_expression: "hecks_tr_rename(state, 'cost', 'amount')".to_string(),
                compiled_id_expression: None,
            }],
        };

        mint_era(&client, domain, 2, &storage_shape::mint_hash(&v2_ir), &to_label, "v2 source text", &[aggregate], &[&edge], None, &[])
            .await
            .expect("mint_era");

        // ── read back through the same generic function real deployment
        // traffic uses — proving the whole chain, not just that SQL ran ──
        let mut rows = journal::read_lineage_head_all(&client, domain, "widget").await.expect("read_lineage_head_all");
        rows.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(
            rows,
            vec![
                ("w1".to_string(), serde_json::json!({"amount": {"cents": 100}, "kind": {"label": "w1"}})),
                ("w2".to_string(), serde_json::json!({"amount": {"cents": 200}, "kind": {"label": "w2"}})),
            ]
        );
    }

    // ───────────── snapshot seed fill ─────────────

    fn registration_default() -> LifecycleDefault {
        LifecycleDefault { key_prefix: "Studio::Registration#".to_string(), field: "status".to_string(), default: "active".to_string() }
    }

    // A seed as the kernel's `instances()` dump writes it: one entry per
    // instance under "Domain::Aggregate#id", value objects as nested objects,
    // a lifecycle field as a plain string.
    fn old_seed() -> Value {
        serde_json::json!({
            "Studio::Event#yoga": {
                "slug": {"value": "yoga"}, "name": {"value": "Yoga"}, "price": {"cents": 100},
                "capacity": {"value": 10}, "status": "open"
            },
            "Studio::Registration#r1": {
                "event_slug": "yoga", "registration_id": {"value": "r1"},
                "attendee": {"name": "Ada", "email": "ada@example.com"}
            },
            "Studio::Registration#r2": {
                "event_slug": "yoga", "registration_id": {"value": "r2"},
                "attendee": {"name": "Grace", "email": "grace@example.com"}
            },
            "Payments::Payment#r1": {"status": "succeeded"}
        })
    }

    #[test]
    fn a_missing_lifecycle_field_gets_the_default() {
        let mut seed = old_seed();
        assert_eq!(fill_lifecycle_defaults(&mut seed, &[registration_default()]), 2);
        assert_eq!(seed["Studio::Registration#r1"]["status"], "active");
        assert_eq!(seed["Studio::Registration#r2"]["status"], "active");
        assert_eq!(seed["Studio::Registration#r1"]["attendee"]["email"], "ada@example.com", "everything else on the instance is kept");
    }

    #[test]
    fn a_null_lifecycle_field_is_filled_too() {
        let mut seed = serde_json::json!({"Studio::Registration#r1": {"status": null}});
        assert_eq!(fill_lifecycle_defaults(&mut seed, &[registration_default()]), 1);
        assert_eq!(seed["Studio::Registration#r1"]["status"], "active");
    }

    #[test]
    fn an_existing_lifecycle_value_is_left_alone() {
        let mut seed = old_seed();
        seed["Studio::Registration#r2"]["status"] = serde_json::json!("archived");
        assert_eq!(fill_lifecycle_defaults(&mut seed, &[registration_default()]), 1);
        assert_eq!(seed["Studio::Registration#r2"]["status"], "archived");
        assert_eq!(seed["Studio::Registration#r1"]["status"], "active");
    }

    #[test]
    fn aggregates_without_a_declared_default_are_untouched() {
        let mut seed = old_seed();
        let before = seed.clone();
        assert_eq!(fill_lifecycle_defaults(&mut seed, &[]), 0);
        assert_eq!(seed, before);

        // Only Registration is named: the Event, the Payment, and an aggregate
        // whose name merely starts with "Registration" stay as they were.
        let mut seed = old_seed();
        seed["Studio::RegistrationNote#n1"] = serde_json::json!({"text": "hi"});
        let mut expected = seed.clone();
        expected["Studio::Registration#r1"]["status"] = serde_json::json!("active");
        expected["Studio::Registration#r2"]["status"] = serde_json::json!("active");
        fill_lifecycle_defaults(&mut seed, &[registration_default()]);
        assert_eq!(seed, expected);
    }

    #[test]
    fn filling_twice_changes_nothing_the_second_time() {
        let mut seed = old_seed();
        fill_lifecycle_defaults(&mut seed, &[registration_default()]);
        let once = seed.clone();
        assert_eq!(fill_lifecycle_defaults(&mut seed, &[registration_default()]), 0);
        assert_eq!(seed, once);
    }

    #[test]
    fn a_seed_that_is_not_an_object_or_holds_a_non_object_instance_is_left_alone() {
        let mut empty = serde_json::json!({});
        assert_eq!(fill_lifecycle_defaults(&mut empty, &[registration_default()]), 0);
        let mut not_a_seed = serde_json::json!([1, 2]);
        assert_eq!(fill_lifecycle_defaults(&mut not_a_seed, &[registration_default()]), 0);
        let mut odd = serde_json::json!({"Studio::Registration#r1": "scalar"});
        assert_eq!(fill_lifecycle_defaults(&mut odd, &[registration_default()]), 0);
        assert_eq!(odd["Studio::Registration#r1"], "scalar");
    }

    #[test]
    fn lifecycle_defaults_are_read_from_the_irs_aggregates() {
        let ir = serde_json::json!({
            "name": "Studio",
            "aggregates": [
                {"name": "Event", "lifecycle": {"field": "status", "default": "open", "transitions": []}},
                {"name": "Registration", "lifecycle": {"field": "status", "default": "active", "transitions": []}},
                {"name": "Note", "lifecycle": null},
                {"name": "Bare"}
            ]
        });
        assert_eq!(
            lifecycle_defaults(&ir),
            vec![
                LifecycleDefault { key_prefix: "Studio::Event#".to_string(), field: "status".to_string(), default: "open".to_string() },
                registration_default(),
            ]
        );
        assert!(lifecycle_defaults(&serde_json::json!({"name": "Studio"})).is_empty());
    }

    /// **The real boot**: the snapshot a live host wrote under the old shape
    /// holds registrations with no `status`; minting the new era fills them
    /// inside the mint's own transaction, and a mint that fails leaves the
    /// snapshot as it was.
    #[tokio::test]
    async fn minting_an_era_fills_lifecycle_defaults_into_the_stored_snapshot() {
        let client = own_scratch_db("hecks_host_mint_snapshot_fill").await;
        journal::ensure_schema(&client).await.expect("ensure_schema");
        ensure_base(&client, "Studio").await.expect("ensure_base");

        fn shape(with_status: bool) -> Value {
            let mut aggregate = serde_json::json!({
                "name": "Registration",
                "identified_by": ["registration_id"],
                "attributes": [{"name": "registration_id", "type": "Id", "list": false}],
                "value_objects": [{"name": "Id", "attributes": [{"name": "value", "type": "String", "list": false}]}],
                "entities": []
            });
            if with_status {
                aggregate["lifecycle"] = serde_json::json!({"field": "status", "default": "active", "transitions": []});
            }
            serde_json::json!({"name": "Studio", "aggregates": [aggregate]})
        }
        let (v1_ir, v2_ir) = (shape(false), shape(true));
        let aggregate = Aggregate { name: "Registration".to_string(), storage_name: "registration".to_string() };
        hold_first(&client, "Studio", "v1 source", &v1_ir, &[aggregate.clone()], None).await.expect("hold_first");
        journal::save_snapshot(&client, 7, &old_seed()).await.expect("save_snapshot");

        let to_label = storage_shape::mint_label(&v2_ir);
        let edge = Edge {
            from: storage_shape::mint_label(&v1_ir),
            to: to_label.clone(),
            aggregates: vec![EdgeAggregate {
                name: "Registration".to_string(),
                was: None,
                has_compute_or_rekey: false,
                compiled_state_expression: "state || jsonb_build_object('status', 'active')".to_string(),
                compiled_id_expression: None,
            }],
        };
        let defaults = lifecycle_defaults(&v2_ir);
        assert_eq!(defaults.len(), 1);
        // The defaults name "Studio::Registration#", matching the seed's keys.
        mint_era(&client, "Studio", 2, &storage_shape::mint_hash(&v2_ir), &to_label, "v2 source", &[aggregate], &[&edge], None, &defaults)
            .await
            .expect("mint_era");

        let snapshot = journal::load_snapshot(&client).await.unwrap().expect("the snapshot row is still there");
        assert_eq!(snapshot.ordinal, 7, "the snapshot's ordinal is not touched, only its instances");
        assert_eq!(snapshot.seed["Studio::Registration#r1"]["status"], "active");
        assert_eq!(snapshot.seed["Studio::Registration#r2"]["status"], "active");
        assert!(snapshot.seed["Studio::Event#yoga"]["status"] == "open" && snapshot.seed["Payments::Payment#r1"]["status"] == "succeeded");
    }

    #[tokio::test]
    async fn filling_a_database_with_no_snapshot_table_or_row_is_a_no_op() {
        let client = own_scratch_db("hecks_host_mint_snapshot_fill_absent").await;
        assert_eq!(fill_snapshot_lifecycle_defaults(&client, "Studio", &[registration_default()]).await.unwrap(), 0, "no table");
        journal::ensure_schema(&client).await.expect("ensure_schema");
        assert_eq!(fill_snapshot_lifecycle_defaults(&client, "Studio", &[registration_default()]).await.unwrap(), 0, "no row");
    }

    // ───────────── era chain SQL ─────────────

    /// The compiled expression `Translation::RuleCompiler#compile_backfill`
    /// writes for one backfilled path, wrapped around `inner`.
    fn backfill_expression(inner: &str, path: &[&str], default_json: &str) -> String {
        let array = format!("ARRAY[{}]::text[]", path.iter().map(|p| format!("'{p}'")).collect::<Vec<_>>().join(", "));
        let label = path.join(".");
        format!(
            "(SELECT CASE WHEN (hecks_tr_extract(__s, {array})).present THEN __s ELSE hecks_tr_insert(__s, {array}, '{default_json}'::jsonb, 'backfill {label}') END FROM (SELECT ({inner}) AS __s) __outer)"
        )
    }

    /// Every row a chain statement yields, as sorted text.
    async fn raw_rows(client: &tokio_postgres::Client, sql: &str) -> Vec<String> {
        let mut rows: Vec<String> = client
            .query(&format!("SELECT ordinal::text || '|' || aggregate_id || '|' || operation || '|' || coalesce(state::text, 'null') FROM ({sql}) c"), &[])
            .await
            .expect("chain query")
            .iter()
            .map(|r| r.get::<_, String>(0))
            .collect();
        rows.sort();
        rows
    }

    fn edge_of(from: &str, to: &str, aggregate: &str, expression: &str) -> Edge {
        Edge {
            from: from.to_string(),
            to: to.to_string(),
            aggregates: vec![EdgeAggregate {
                name: aggregate.to_string(),
                was: None,
                has_compute_or_rekey: false,
                compiled_state_expression: expression.to_string(),
                compiled_id_expression: None,
            }],
        }
    }

    /// The statement text carries the fence on the tail and on every edge, for any
    /// chain length: that is what keeps the planner from copying an edge's
    /// expression into each read of `state`.
    #[test]
    fn every_cte_of_the_chain_is_materialized() {
        let watermarks = std::collections::HashMap::new();
        let edges: Vec<Edge> = (1..=6).map(|n| edge_of(&format!("e{n}"), &format!("e{}", n + 1), "Registration", "state")).collect();
        for n in 1..=6usize {
            let chain: Vec<&Edge> = edges[..n].iter().collect();
            let sql = chain_sql("Chain", "Registration", (n + 1) as i32, &chain, &watermarks);
            assert!(sql.starts_with("WITH tail AS MATERIALIZED ("), "{sql}");
            assert_eq!(sql.matches("AS MATERIALIZED (").count(), n + 1, "the tail and each of the {n} edges: {sql}");
            for edge in 1..=n {
                assert!(sql.contains(&format!("edge_{edge} AS MATERIALIZED (")), "edge {edge}: {sql}");
            }
        }
    }

    /// **The plan stays linear in the chain length**. The statement text is short
    /// either way; what exploded was the planner's copy of each previous edge's
    /// expression into every read of `state`. Counting the plan's lines is the
    /// deterministic way to see it (a timing assertion would flake): a 12-edge
    /// chain of the shape a real deployment has (one rule-heavy edge, identity
    /// edges after it) stays small when fenced, and an unfenced 5-edge chain is
    /// already many times the size of the fenced one.
    #[tokio::test]
    async fn the_chain_plan_grows_with_the_edges_not_exponentially() {
        let client = own_scratch_db("hecks_host_mint_chain_plan_size").await;
        journal::ensure_schema(&client).await.expect("ensure_schema");
        let aggregates = vec![Aggregate { name: "Registration".to_string(), storage_name: "registration".to_string() }];
        hold_first(&client, "Plan", "era 1", &serde_json::json!({"name": "Plan", "aggregates": []}), &aggregates, None).await.expect("hold_first");

        let mut heavy = "hecks_tr_drop(state, ARRAY['attendee', 'name']::text[])".to_string();
        for field in ["first_name", "last_name", "phone", "how_heard", "aim"] {
            heavy = backfill_expression(&heavy, &["attendee", field], "\"(none)\"");
        }
        let mut edges = vec![edge_of("e1", "e2", "Registration", &heavy)];
        for n in 2..=11 {
            edges.push(edge_of(&format!("e{n}"), &format!("e{}", n + 1), "Registration", "state"));
        }
        edges.push(edge_of("e12", "e13", "Registration", &backfill_expression("state", &["status"], "\"active\"")));

        let watermarks = std::collections::HashMap::new();
        let plan_lines = |chain: &[&Edge], materialize: bool| {
            let sql = chain_sql_with("Plan", "Registration", (chain.len() + 1) as i32, chain, &watermarks, materialize);
            let client = &client;
            async move { client.query(&format!("EXPLAIN (COSTS OFF) {sql}"), &[]).await.expect("explain").len() }
        };

        let all: Vec<&Edge> = edges.iter().collect();
        let fenced_12 = plan_lines(&all, true).await;
        let fenced_6 = plan_lines(&all[..6], true).await;
        assert!(fenced_12 < 2 * fenced_6.max(500), "12 fenced edges plan to {fenced_12} lines, 6 to {fenced_6}");
        let inlined_5 = plan_lines(&all[..5], false).await;
        let fenced_5 = plan_lines(&all[..5], true).await;
        assert!(inlined_5 > 10 * fenced_5, "unfenced 5 edges: {inlined_5} plan lines; fenced: {fenced_5}");
    }

    /// **Same rows, either way**. Materializing each edge's CTE (the fix for the
    /// planner copying every previous edge's expression into each read of
    /// `state`) must not change one row of any chain. Five eras of history,
    /// with a delete, a re-saved id and shapes that only some edges touch, over
    /// every chain length, for both aggregates, compared as the raw chain output
    /// and as the latest-per-id result the audit and the head build read.
    #[tokio::test]
    async fn materializing_the_edge_ctes_returns_exactly_the_rows_the_inlined_chain_does() {
        let client = own_scratch_db("hecks_host_mint_chain_differential").await;
        journal::ensure_schema(&client).await.expect("ensure_schema");
        let domain = "Chain";
        let aggregates = vec![
            Aggregate { name: "Registration".to_string(), storage_name: "registration".to_string() },
            Aggregate { name: "Event".to_string(), storage_name: "event".to_string() },
        ];
        let ir = serde_json::json!({"name": domain, "aggregates": []});
        hold_first(&client, domain, "era 1", &ir, &aggregates, None).await.expect("hold_first");

        // Edge 1 backfills four nested paths; edges 2 and 3 carry no rule (as
        // most of a real deployment's edges do); edge 4 backfills one more.
        let mut nested = "hecks_tr_drop(state, ARRAY['attendee', 'name']::text[])".to_string();
        for field in ["first_name", "last_name", "phone", "aim"] {
            nested = backfill_expression(&nested, &["attendee", field], "\"(none)\"");
        }
        let edges = vec![
            edge_of("e1", "e2", "Registration", &nested),
            edge_of("e2", "e3", "Event", "state"),
            edge_of("e3", "e4", "Event", "state"),
            edge_of("e4", "e5", "Registration", &backfill_expression("state", &["status"], "\"active\"")),
        ];

        let journal_name = "hecks_journal_chain";
        let insert = |era: i32, aggregate: &str, id: &str, operation: &str, state: Value| {
            let client = &client;
            let (aggregate, id, operation) = (aggregate.to_string(), id.to_string(), operation.to_string());
            async move {
                client
                    .execute(
                        &format!("INSERT INTO {journal_name} (era, aggregate, aggregate_id, operation, state) VALUES ($1, $2, $3, $4, $5)"),
                        &[&era, &aggregate, &id, &operation, &state],
                    )
                    .await
                    .expect("journal insert");
            }
        };
        for era in 1..=5i32 {
            // era 1 carries the old attendee shape, later eras the new one
            let attendee = |n: &str| if era == 1 { serde_json::json!({"name": n, "email": "a@example.com"}) } else { serde_json::json!({"first_name": n, "email": "a@example.com"}) };
            for i in 0..6 {
                let id = format!("r{}", (era as usize + i) % 5);
                insert(era, "registration", &id, "save", serde_json::json!({"attendee": attendee(&format!("n{era}{i}"))})).await;
            }
            insert(era, "event", &format!("e{era}"), "save", serde_json::json!({"name": {"value": format!("event {era}")}})).await;
            insert(era, "event", "e1", "save", serde_json::json!({"name": {"value": "renamed"}})).await;
            if era == 3 {
                insert(era, "registration", "r0", "delete", Value::Null).await;
            }
            if era < 5 {
                let chain: Vec<&Edge> = edges[..era as usize].iter().collect();
                mint_era(&client, domain, era + 1, &"h".repeat(64), &format!("e{}", era + 1), "text", &aggregates, &chain, None, &[]).await.expect("mint_era");
            }
        }

        let held = journal::held_eras(&client, domain).await.unwrap();
        let watermarks: std::collections::HashMap<i32, Option<i64>> = held.iter().map(|h| (h.ordinal, h.watermark)).collect();
        let mut compared = 0;
        for aggregate in &aggregates {
            for n in 1..=edges.len() {
                let chain: Vec<&Edge> = edges[..n].iter().collect();
                let era = (n + 1) as i32;
                let inlined = chain_sql_with(domain, &aggregate.name, era, &chain, &watermarks, false);
                let fenced = chain_sql_with(domain, &aggregate.name, era, &chain, &watermarks, true);
                assert_ne!(inlined, fenced, "the two forms really differ");
                assert!(fenced.contains("AS MATERIALIZED (") && !inlined.contains("MATERIALIZED"));

                let (a, b) = (raw_rows(&client, &inlined).await, raw_rows(&client, &fenced).await);
                assert!(!a.is_empty(), "{} chain of {n}: the fixture yields rows", aggregate.name);
                assert_eq!(a, b, "{} chain of {n}: raw rows", aggregate.name);
                assert_eq!(
                    latest_of(&client, &inlined).await.unwrap(),
                    latest_of(&client, &fenced).await.unwrap(),
                    "{} chain of {n}: latest per id",
                    aggregate.name
                );
                compared += 1;
            }
        }
        assert_eq!(compared, 8);
        // and the fixture exercised what it claims to: a backfilled status reached the head
        let translated = translated_latest(&client, domain, "Registration", 5, &edges.iter().collect::<Vec<_>>(), &watermarks).await.unwrap();
        assert!(translated.values().all(|state| state["status"] == "active"), "{translated:?}");
        assert_eq!(translated.len(), 5, "five registrations were ever saved: {translated:?}");
    }


    // Layer 2 proven live, both directions: a raw edge whose declared
    // rules genuinely agree with what the compiled SQL does passes
    // silently; one that doesn't (the exact real bug this audit exists
    // to catch — a scaffolded/hand-edited edge whose declared `renames:`
    // disagrees with its own `compiled_state_expression`) refuses before
    // anything mints, naming the exact divergence. Two domains, one
    // scratch database, to amortize setup — `audit_before_mint` itself
    // is the only thing under test, not `mint_era`'s own transaction.
    #[tokio::test]
    async fn audit_before_mint_passes_a_true_edge_and_refuses_a_lying_one() {
        let db = "rust_host_audit_test";
        let owner = "rust_host_audit_owner";

        let admin = tokio_postgres::connect("host=localhost dbname=postgres", NoTls).await;
        let (admin_client, admin_connection) = admin.expect("connect to postgres as admin");
        tokio::spawn(async move {
            let _ = admin_connection.await;
        });
        let _ = admin_client.batch_execute(&format!("DROP DATABASE IF EXISTS {db} WITH (FORCE)")).await;
        admin_client.batch_execute(&format!("CREATE DATABASE {db}")).await.expect("create scratch db");
        let _ = admin_client.batch_execute(&format!("DROP ROLE IF EXISTS {owner}")).await;
        admin_client.batch_execute(&format!("CREATE ROLE {owner} LOGIN")).await.expect("create owner role");
        admin_client.batch_execute(&format!("GRANT CONNECT ON DATABASE {db} TO {owner}")).await.expect("grant connect");

        let grant = tokio_postgres::connect(&format!("host=localhost dbname={db}"), NoTls).await;
        let (grant_client, grant_connection) = grant.expect("connect to scratch db as superuser to grant schema rights");
        tokio::spawn(async move {
            let _ = grant_connection.await;
        });
        grant_client.batch_execute(&format!("GRANT USAGE, CREATE ON SCHEMA public TO {owner}")).await.expect("grant schema rights");
        grant_client.batch_execute(&format!("ALTER DATABASE {db} OWNER TO {owner}")).await.expect("make owner the db owner");

        let (client, connection) = tokio_postgres::connect(&format!("host=localhost dbname={db} user={owner}"), NoTls).await.expect("connect as owner");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        fn shape(attribute_name: &str) -> Value {
            serde_json::json!({
                "name": "AuditTest",
                "aggregates": [{
                    "name": "Widget",
                    "identified_by": ["kind"],
                    "attributes": [
                        {"name": attribute_name, "type": "Money", "list": false},
                        {"name": "kind", "type": "Kind", "list": false}
                    ],
                    "value_objects": [
                        {"name": "Money", "attributes": [{"name": "cents", "type": "Integer", "list": false}]},
                        {"name": "Kind", "attributes": [{"name": "label", "type": "String", "list": false}]}
                    ],
                    "entities": []
                }]
            })
        }
        let v1_ir = shape("cost");
        let v2_ir = shape("amount");
        let aggregate = Aggregate { name: "Widget".to_string(), storage_name: "widget".to_string() };
        let from_label = storage_shape::mint_label(&v1_ir);
        let to_label = storage_shape::mint_label(&v2_ir);

        async fn seed_era_one(client: &tokio_postgres::Client, domain: &str, v1_ir: &Value, aggregate: &Aggregate) {
            hold_first(client, domain, "v1 source text", v1_ir, std::slice::from_ref(aggregate), None).await.expect("hold_first");
            let config = journal::LineageConfig { domain: domain.to_string(), era: Some(1), mirrored: None };
            journal::append_lineage_mutation(
                client,
                &config,
                &journal::Mutation { aggregate: "Widget", id: "w1", operation: "save", state: &serde_json::json!({"cost": {"cents": 100}, "kind": {"label": "w1"}}) },
            )
            .await
            .expect("write w1 under era 1");
        }

        // ── the honest edge: declared renames genuinely match the
        // compiled SQL — audit_before_mint must find nothing wrong ──
        let honest_domain = "AuditPass";
        seed_era_one(&client, honest_domain, &v1_ir, &aggregate).await;
        let honest_edge = Edge {
            from: from_label.clone(),
            to: to_label.clone(),
            aggregates: vec![EdgeAggregate {
                name: "Widget".to_string(),
                was: None,
                has_compute_or_rekey: false,
                compiled_state_expression: "hecks_tr_rename(state, 'cost', 'amount')".to_string(),
                compiled_id_expression: None,
            }],
        };
        let honest_raw_edges = vec![serde_json::json!({
            "domain": honest_domain, "from": from_label, "to": to_label,
            "aggregates": [{"name": "Widget", "renames": {"cost": "amount"}}]
        })];
        let watermarks: std::collections::HashMap<i32, Option<i64>> = [(1, None)].into_iter().collect();
        audit_before_mint(&client, honest_domain, &v2_ir, &[aggregate.clone()], 2, &[&honest_edge], &honest_raw_edges, &watermarks)
            .await
            .expect("an honest edge's audit must pass silently");

        // ── the lying edge: declared `renames:` claims a different
        // destination than the compiled SQL actually produces — the
        // exact real-world bug this audit exists to catch (a
        // hand-edited or stale scaffold whose declaration and compiled
        // SQL have drifted apart). Must refuse, naming the divergence,
        // before anything mints. ──
        let lying_domain = "AuditFail";
        seed_era_one(&client, lying_domain, &v1_ir, &aggregate).await;
        let lying_edge = honest_edge.clone();
        let lying_raw_edges = vec![serde_json::json!({
            "domain": lying_domain, "from": from_label, "to": to_label,
            // Claims `cost` becomes `price` -- the compiled SQL above
            // still renames it to `amount`. A real divergence.
            "aggregates": [{"name": "Widget", "renames": {"cost": "price"}}]
        })];
        let error = audit_before_mint(&client, lying_domain, &v2_ir, &[aggregate], 2, &[&lying_edge], &lying_raw_edges, &watermarks)
            .await
            .expect_err("a declared rename that disagrees with the compiled SQL must refuse");
        let message = format!("{error:#}");
        assert!(message.contains("the audit refused"), "{message}");
        assert!(message.contains("diverges from the reference transform"), "{message}");
    }
}
