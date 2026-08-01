//! The Postgres persistence adapter — the Rust twin of
//! lib/hecksagain/adapters/driven/postgres/. The only adapter that
//! declares the LINEAGE capability: it may act on shape drift where
//! every other adapter refuses toward it. This side never MINTS an era
//! though — era identity is computed once, by the Ruby scaffold, and
//! stored; a Rust boot recognizes stored eras structurally and refuses
//! toward the Ruby side on anything unminted.
//!
//! Storage model (identical DDL to the Ruby side, so either runtime can
//! boot a database the other wrote):
//! - one journal per DOMAIN, list-partitioned by era, one ordinal
//!   sequence spanning partitions; appends only — UPDATE and DELETE are
//!   revoked (immutability by privilege; the owner's implicit rights
//!   remain, a deployment's app role connects as a non-owner);
//! - per aggregate, the HEAD is a derived view (era 1: latest save per
//!   id; later eras: the Ruby-minted matview of the translated ancestor
//!   tail overlaid with live current-era rows);
//! - state is ONE jsonb column. jsonb normalizes key order, so anything
//!   comparing stored state (the parity history gate) must compare
//!   canonicalized state — `bin/canonicalise` deep-sorts keys, which is
//!   exactly why the gate survives this normalization.
//!
//! Query pushdown follows Ruby's contract — every operator the IR can
//! declare compiles fully into SQL; the two ops that cannot (`in`,
//! `none_in_state`) decline pushdown entirely rather than half-answer.

use postgres::{Client, NoTls};
use std::collections::HashMap;
use std::sync::Mutex;
use storehouse::bluebook::translation::ir::Translation;
use storehouse::heki;
use storehouse::ir::{WhereClause, WhereOp};
use storehouse::ports::persistence::ReplicationEntry;
use storehouse::runtime::AggregateState;
use storehouse::value_bridge;

pub struct PostgresRepository {
    client: Mutex<Client>,
    table: String,
    domain: String,
    era: i32,
    store: HashMap<String, AggregateState>,
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn text_literal(text: &str) -> String {
    format!("'{}'", text.replace('\'', "''"))
}

struct EraRow {
    ordinal: i32,
    label: Option<String>,
    held_text: String,
}

/// Byte-identical with Ruby's `Ports::Persistence::EraTamper` — when
/// the digest fails, say WHICH situation the operator is in, by the
/// structural comparison every boot already trusts.
fn integrity_refusal(domain: &str, ordinal: i32, edited_text: &str, stored_projection: Option<&serde_json::Value>) -> String {
    let base = format!("cannot boot {domain}: the held text of era {ordinal} was edited after it was frozen");
    if let Some(stored) = stored_projection {
        let edited = crate::shape_of(edited_text);
        if edited == *stored {
            return format!(
                "{base} — the edit is cosmetic to the storage shape; \
                 re-attest it (bin/reattest_era), or restore the original text from the era archive"
            );
        }
        return format!(
            "{base} AND the edit changed the storage shape — \
             re-attestation will refuse it; restore the original text from the era archive"
        );
    }
    format!("{base} — held era texts are storage facts; restore the original text, or reset the data")
}

impl PostgresRepository {
    // NO `identified_by`: a repository is handed an id already derived by
    // `identity::of`, so there was never a question the identity could answer.
    pub fn new(aggregate_type: &str, database: &str, domain: &str) -> Result<Self, String> {
        let config = if database.starts_with("postgres://") || database.starts_with("postgresql://") {
            database.to_string()
        } else {
            format!("host=localhost dbname={database}")
        };
        let mut client = Client::connect(&config, NoTls)
            .map_err(|error| format!("cannot bind Postgres at {database} for {aggregate_type}: {error}"))?;

        let table = storehouse::naming::snake(aggregate_type);
        let domain = if domain.is_empty() { aggregate_type } else { domain };
        let journal = format!("hecks_journal_{}", storehouse::naming::snake(domain));
        Self::ensure_base(&mut client, &journal)?;

        let era = Self::current_era(&mut client, domain)?;
        if era == 1 {
            Self::ensure_first_head(&mut client, &journal, &table)?;
        }

        let mut repository = PostgresRepository {
            client: Mutex::new(client),
            table,
            domain: domain.to_string(),
            era,
            store: HashMap::new(),
        };
        repository.load_persisted()?;
        Ok(repository)
    }

    fn journal(&self) -> String {
        format!("hecks_journal_{}", storehouse::naming::snake(&self.domain))
    }

    fn head_view(&self) -> String {
        format!("{}_head", self.table)
    }

    fn ensure_base(client: &mut Client, journal: &str) -> Result<(), String> {
        let statements = [
            "CREATE TABLE IF NOT EXISTS hecks_eras (\
               domain    text NOT NULL,\
               ordinal   int  NOT NULL,\
               hash      text,\
               label     text,\
               held_text text NOT NULL,\
               watermark bigint,\
               PRIMARY KEY (domain, ordinal)\
             )"
            .to_string(),
            format!("CREATE SEQUENCE IF NOT EXISTS {}", quote_ident(&format!("{journal}_ordinal"))),
            format!(
                "CREATE TABLE IF NOT EXISTS {} (\
                   ordinal      bigint NOT NULL DEFAULT nextval('{journal}_ordinal'),\
                   era          int    NOT NULL,\
                   aggregate    text   NOT NULL,\
                   aggregate_id text   NOT NULL,\
                   operation    text   NOT NULL DEFAULT 'save',\
                   state        jsonb,\
                   mirrors      jsonb\
                 ) PARTITION BY LIST (era)",
                quote_ident(journal)
            ),
            format!(
                "CREATE TABLE IF NOT EXISTS {} PARTITION OF {} FOR VALUES IN (1)",
                quote_ident(&format!("{journal}_era_1")),
                quote_ident(journal)
            ),
            format!("REVOKE UPDATE, DELETE ON {} FROM PUBLIC", quote_ident(journal)),
            "ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_digest text".to_string(),
            "ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_projection jsonb".to_string(),
            "CREATE TABLE IF NOT EXISTS hecks_era_texts (               domain      text NOT NULL,               ordinal     int  NOT NULL,               digest      text NOT NULL,               held_text   text NOT NULL,               archived_at timestamptz NOT NULL DEFAULT now(),               PRIMARY KEY (domain, ordinal, digest)             )"
            .to_string(),
        ];
        for ddl in statements {
            client.batch_execute(&ddl).map_err(|error| format!("cannot create lineage tables: {error}"))?;
        }
        Ok(())
    }

    fn ensure_first_head(client: &mut Client, journal: &str, table: &str) -> Result<(), String> {
        let exists = client
            .query(
                "SELECT 1 FROM information_schema.views WHERE table_name = $1 \
                 UNION SELECT 1 FROM pg_matviews WHERE matviewname = $1",
                &[&format!("{table}_head")],
            )
            .map_err(|error| format!("cannot inspect views: {error}"))?;
        if !exists.is_empty() {
            return Ok(());
        }
        client
            .batch_execute(&format!(
                "CREATE OR REPLACE VIEW {} AS \
                 SELECT id, state FROM ( \
                   SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state \
                   FROM {} WHERE aggregate = {} ORDER BY aggregate_id, ordinal DESC \
                 ) latest WHERE operation = 'save'",
                quote_ident(&format!("{table}_head")),
                quote_ident(journal),
                text_literal(table)
            ))
            .map_err(|error| format!("cannot create {table} head view: {error}"))
    }

    fn current_era(client: &mut Client, domain: &str) -> Result<i32, String> {
        let rows = client
            .query("SELECT COALESCE(max(ordinal), 1) AS era FROM hecks_eras WHERE domain = $1", &[&domain])
            .map_err(|error| format!("cannot read hecks_eras: {error}"))?;
        Ok(rows.first().map(|row| row.get::<_, i32>(0)).unwrap_or(1))
    }

    /// Every held text is verified against its raw-byte digest on the
    /// way out — an edited storage fact refuses rather than silently
    /// reporting "no drift". Rows from before the check existed are
    /// backfilled, not refused. (This is NOT era naming: identity
    /// hashes the canonical projection, minted once, Ruby-side only.)
    fn eras(&self) -> Result<Vec<EraRow>, String> {
        let mut client = self.client.lock().expect("postgres client poisoned");
        let rows = client
            .query(
                "SELECT ordinal, label, held_text, held_digest, held_projection::text FROM hecks_eras WHERE domain = $1 ORDER BY ordinal",
                &[&self.domain],
            )
            .map_err(|error| format!("cannot read hecks_eras: {error}"))?;
        let mut held = Vec::with_capacity(rows.len());
        for row in rows {
            let ordinal: i32 = row.get(0);
            let held_text: String = row.get(2);
            let stored_digest: Option<String> = row.get(3);
            let stored_projection: Option<String> = row.get(4);
            let digest = storehouse::util::sha256_hex(held_text.as_bytes());
            let authentic = match stored_digest {
                None => {
                    client
                        .execute(
                            "UPDATE hecks_eras SET held_digest = $3 WHERE domain = $1 AND ordinal = $2 AND held_digest IS NULL",
                            &[&self.domain, &ordinal, &digest],
                        )
                        .map_err(|error| format!("cannot backfill hecks_eras integrity: {error}"))?;
                    true
                }
                Some(stored) if stored == digest => true,
                Some(_) => false,
            };
            if !authentic {
                let projection = stored_projection.and_then(|json| serde_json::from_str(&json).ok());
                return Err(integrity_refusal(&self.domain, ordinal, &held_text, projection.as_ref()));
            }
            // A verified-authentic text backfills what older rows lack:
            // its projection and its archive copy. Never on a text that
            // failed verification — that would bless the edit.
            client
                .execute(
                    "INSERT INTO hecks_era_texts (domain, ordinal, digest, held_text) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
                    &[&self.domain, &ordinal, &digest, &held_text],
                )
                .map_err(|error| format!("cannot archive era text: {error}"))?;
            if stored_projection.is_none() {
                let projection = crate::shape_of(&held_text);
                client
                    .execute(
                        "UPDATE hecks_eras SET held_projection = $3::text::jsonb WHERE domain = $1 AND ordinal = $2 AND held_projection IS NULL",
                        &[&self.domain, &ordinal, &serde_json::to_string(&projection).unwrap_or_default()],
                    )
                    .map_err(|error| format!("cannot backfill era projection: {error}"))?;
            }
            held.push(EraRow { ordinal, label: row.get(1), held_text });
        }
        Ok(held)
    }

    fn load_persisted(&mut self) -> Result<(), String> {
        let rows = self
            .client
            .lock()
            .expect("postgres client poisoned")
            .query(&format!("SELECT id, state::text FROM {} ORDER BY id", quote_ident(&self.head_view())), &[])
            .map_err(|error| format!("cannot read {}: {error}", self.table))?;

        for row in rows {
            let id: String = row.get(0);
            let state_json: String = row.get(1);
            let fields: serde_json::Map<String, serde_json::Value> =
                serde_json::from_str(&state_json).map_err(|error| format!("cannot decode {} state: {error}", self.table))?;
            let state = value_bridge::to_state(&id, &fields);
            self.store.insert(state.id.clone(), state);
        }
        Ok(())
    }

    fn append(&self, id: &str, operation: &str, state_json: Option<&str>, mirrors_json: &str) -> Result<(), String> {
        self.client
            .lock()
            .expect("postgres client poisoned")
            .execute(
                &format!(
                    "INSERT INTO {} (era, aggregate, aggregate_id, operation, state, mirrors) \
                     VALUES ($1, $2, $3, $4, $5::text::jsonb, $6::text::jsonb)",
                    quote_ident(&self.journal())
                ),
                &[&self.era, &self.table, &id, &operation, &state_json, &mirrors_json],
            )
            .map_err(|error| format!("cannot append {} history: {error}", self.table))?;
        Ok(())
    }

    pub fn save_with_mirrors(
        &mut self,
        state: AggregateState,
        mirrors: Vec<String>,
        _ctx: heki::WriteContext<'_>,
    ) -> Result<(), String> {
        let state_json = serde_json::to_string(&value_bridge::from_state(&state)).unwrap_or_default();
        let mirrors_json = serde_json::to_string(&mirrors).unwrap_or_default();
        self.append(&state.id.clone(), "save", Some(&state_json), &mirrors_json)?;
        self.store.insert(state.id.clone(), state);
        Ok(())
    }

    pub fn delete_with_mirrors(&mut self, id: &str, mirrors: Vec<String>, _ctx: heki::WriteContext<'_>) -> Result<(), String> {
        let mirrors_json = serde_json::to_string(&mirrors).unwrap_or_default();
        self.append(id, "delete", None, &mirrors_json)?;
        self.store.remove(id);
        Ok(())
    }

    pub fn replication_entries(&self) -> Result<Vec<ReplicationEntry>, String> {
        let rows = self
            .client
            .lock()
            .expect("postgres client poisoned")
            .query(
                &format!(
                    "SELECT aggregate_id, operation, state::text, mirrors::text FROM {} \
                     WHERE aggregate = $1 ORDER BY ordinal",
                    quote_ident(&self.journal())
                ),
                &[&self.table],
            )
            .map_err(|error| format!("cannot read {} history: {error}", self.table))?;

        rows.into_iter()
            .map(|row| {
                let id: String = row.get(0);
                let operation: String = row.get(1);
                let state_json: Option<String> = row.get(2);
                let mirrors_json: Option<String> = row.get(3);
                let state = state_json
                    .map(|json| {
                        serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&json)
                            .map(|fields| value_bridge::to_state(&id, &fields))
                            .map_err(|error| format!("cannot decode {} history: {error}", self.table))
                    })
                    .transpose()?;
                let mirrors = mirrors_json
                    .map(|json| serde_json::from_str(&json).unwrap_or_default())
                    .unwrap_or_default();
                Ok(ReplicationEntry { operation, id, state, mirrors })
            })
            .collect()
    }

    /// CANDIDATES, NEVER FINAL ROWS — the trait's contract. Pushdown
    /// here must never under-return; the dispatcher re-applies the
    /// whole predicate to whatever comes back. A value-object column
    /// therefore gets the same reading SQLite's `scalar_of` gives it —
    /// dig the conventional `value` member first, fall back to the
    /// column's own text — and a comparison the jsonb cast cannot
    /// express errors into the `None` fallback (use `all()`), never
    /// into an empty "provably nothing".
    pub fn query(&self, wheres: &[WhereClause], attrs: &HashMap<String, String>) -> Option<Vec<AggregateState>> {
        let mut clauses: Vec<String> = vec![];
        for clause in wheres {
            let segments: Vec<&str> = clause.field.split('.').collect();
            let expression = if segments.len() == 1 {
                format!(
                    "COALESCE(state #>> '{{{field},value}}', state #>> '{{{field}}}')",
                    field = segments[0]
                )
            } else {
                format!("state #>> '{{{}}}'", segments.join(","))
            };
            // A `:kwarg` value reads the caller's argument, same as
            // SQLite's `resolve`. An argument that resolves to nothing
            // SKIPS the clause — candidates may over-return, never
            // under-return against a literal ":name" string.
            let target = match clause.value.strip_prefix(':') {
                Some(kwarg) => match attrs.get(kwarg) {
                    Some(value) if !value.is_empty() => value.clone(),
                    _ => continue,
                },
                None => clause.value.clone(),
            };
            let numeric = target.parse::<f64>().is_ok();
            let (lhs, rhs) = if numeric {
                (format!("({expression})::numeric"), target.clone())
            } else {
                (expression.clone(), text_literal(&target))
            };
            let compiled = match clause.op {
                WhereOp::Eq => format!("{lhs} = {rhs}"),
                WhereOp::Ne => format!("{lhs} <> {rhs}"),
                WhereOp::Gt => format!("{lhs} > {rhs}"),
                WhereOp::Gte => format!("{lhs} >= {rhs}"),
                WhereOp::Lt => format!("{lhs} < {rhs}"),
                WhereOp::Lte => format!("{lhs} <= {rhs}"),
                WhereOp::Contains => format!("position({rhs} in {expression}) > 0"),
                WhereOp::In => return None,
            };
            clauses.push(compiled);
        }

        let mut sql = format!("SELECT id, state::text FROM {}", quote_ident(&self.head_view()));
        if !clauses.is_empty() {
            sql.push_str(&format!(" WHERE {}", clauses.join(" AND ")));
        }
        sql.push_str(" ORDER BY id");

        let rows = self.client.lock().expect("postgres client poisoned").query(&sql, &[]).ok()?;
        Some(
            rows.into_iter()
                .filter_map(|row| {
                    let id: String = row.get(0);
                    let state_json: String = row.get(1);
                    serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&state_json)
                        .ok()
                        .map(|fields| value_bridge::to_state(&id, &fields))
                })
                .collect(),
        )
    }

    // A record is seeded under the id it already carries; the counter upkeep
    // that used to be here was the mint's bookkeeping, not the store's.
    pub fn seed_record(&mut self, state: AggregateState) {
        self.store.insert(state.id.clone(), state);
    }
}

impl storehouse::runtime::PersistenceAdapter for PostgresRepository {
    fn find(&self, id: &str) -> Option<&AggregateState> {
        self.store.get(id)
    }
    fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> {
        self.store.get_mut(id)
    }
    fn all(&self) -> Vec<&AggregateState> {
        self.store.values().collect()
    }
    fn count(&self) -> usize {
        self.store.len()
    }
    fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.save_with_mirrors(state, vec![], ctx)
    }
    fn save_with_mirrors(&mut self, state: AggregateState, mirrors: Vec<String>, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.save_with_mirrors(state, mirrors, ctx)
    }
    fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.delete_with_mirrors(id, vec![], ctx)
    }
    fn delete_with_mirrors(&mut self, id: &str, mirrors: Vec<String>, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.delete_with_mirrors(id, mirrors, ctx)
    }
    fn replication_entries(&self) -> Result<Vec<ReplicationEntry>, String> {
        self.replication_entries()
    }
    fn lineage_capable(&self) -> bool {
        true
    }

    /// The Postgres era gate, Rust side: recognize the stored era
    /// structurally, hold era 1 on a first boot, PERMIT an old checkout
    /// booting a held-but-superseded era (returning its era so its
    /// writes land in its own partition) — and refuse toward the Ruby
    /// scaffold on anything unminted, because this side never computes
    /// an era name. The no-edge refusal is byte-identical with the Ruby
    /// manager's.
    fn era_gate(
        &mut self,
        domain_name: &str,
        current_text: &str,
        current_shape: &serde_json::Value,
        translations: &[Translation],
    ) -> Result<Option<i32>, String> {
        let eras = self.eras()?;
        if eras.is_empty() {
            self.client
                .lock()
                .expect("postgres client poisoned")
                .execute(
                    "INSERT INTO hecks_eras (domain, ordinal, held_text, held_digest, held_projection) VALUES ($1, 1, $2, $3, $4::text::jsonb) ON CONFLICT DO NOTHING",
                    &[
                        &self.domain,
                        &current_text,
                        &storehouse::util::sha256_hex(current_text.as_bytes()),
                        &serde_json::to_string(current_shape).unwrap_or_default(),
                    ],
                )
                .map_err(|error| format!("cannot hold era 1 of {domain_name}: {error}"))?;
            self.client
                .lock()
                .expect("postgres client poisoned")
                .execute(
                    "INSERT INTO hecks_era_texts (domain, ordinal, digest, held_text) VALUES ($1, 1, $2, $3) ON CONFLICT DO NOTHING",
                    &[&self.domain, &storehouse::util::sha256_hex(current_text.as_bytes()), &current_text],
                )
                .map_err(|error| format!("cannot archive era 1 of {domain_name}: {error}"))?;
            return Ok(Some(1));
        }

        let latest = eras.last().expect("eras is non-empty");
        let shape_of = |text: &str| crate::shape_of(text);
        if shape_of(&latest.held_text) == *current_shape {
            return Ok(Some(latest.ordinal));
        }

        for era in &eras[..eras.len() - 1] {
            if shape_of(&era.held_text) == *current_shape {
                // Held but superseded — the old world keeps booting its
                // era and writing its own partition; the new head's
                // watermark already excludes those post-cut writes.
                return Ok(Some(era.ordinal));
            }
        }

        let next = latest.ordinal + 1;
        let has_edge = latest
            .label
            .as_deref()
            .map(|label| translations.iter().any(|t| t.domain == domain_name && t.from == label))
            .unwrap_or(false);
        if !has_edge {
            return Err(format!(
                "cannot boot {domain_name}: the shape changed (era {next}) and no translation edge \
                 covers it — run bin/scaffold_translation to write the edge, \
                 check it with bin/translation_audit, then boot again"
            ));
        }
        Err(format!(
            "cannot boot {domain_name}: era {next} is not minted — minting is Ruby-only; \
             boot the domain from Ruby to mint it, then boot here again"
        ))
    }

    fn adopt_era(&mut self, era: i32) {
        self.era = era;
    }

    fn query(&self, wheres: &[WhereClause], attrs: &HashMap<String, String>) -> Option<Vec<AggregateState>> {
        self.query(wheres, attrs)
    }
    fn seed_record(&mut self, state: AggregateState) {
        self.seed_record(state)
    }
}

pub fn postgres_factory(
    spec: &storehouse::runtime::PersistenceSpec,
) -> Result<Box<dyn storehouse::runtime::PersistenceAdapter>, String> {
    let aggregate = &spec.aggregate;
    let database = spec.option("database").or_else(|| spec.option("db")).ok_or_else(|| {
        format!(
            "{} binds Postgres, which needs a database connection, but its world declares no \"database\".",
            aggregate.name
        )
    })?;
    let domain = spec.option("domain").unwrap_or("").to_string();
    let repository = PostgresRepository::new(&aggregate.name, database, &domain)?;
    Ok(Box::new(repository))
}

pub fn register() {
    storehouse::runtime::register_persistence_adapter("postgres", postgres_factory);
}
