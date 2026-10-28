//! The journal's data and names: what a domain's journal rows look like and how its relations are
//! named. Free of any driver; the SQL that reads and writes them is `store::journal_sql`.

use sha2::{Digest, Sha256};

/// The kernel's cached "instances" output as of `ordinal`, which lets a replay skip the steps
/// before it.
#[derive(Clone)]
pub struct Snapshot {
    pub ordinal: i64,
    pub seed: serde_json::Value,
    /// One-time latch: false only for a snapshot written before saga
    /// durability shipped, never a live signal about current saga state.
    pub sagas_backfilled: bool,
}

/// One live saga/process-manager instance, as stored in `hecks_lambda_sagas`.
#[derive(Clone)]
pub struct SagaRow {
    pub process_manager: String,
    pub correlation: String,
    pub state: String,
    pub memory: serde_json::Value,
    pub completed_compensations: serde_json::Value,
}

/// Which domain journal this binary writes as, and which era. Read from
/// `HECKS_DOMAIN`/main.rs's boot-time mint decision, never computed here.
pub struct LineageConfig {
    pub domain: String,
    /// `None` when lineage isn't provisioned for this domain (ADR 0034).
    pub era: Option<i32>,
    /// Aggregates mirrored into era-shaped head snapshots; `None` means all.
    pub mirrored: Option<std::collections::BTreeSet<String>>,
    /// How many lineage rows a commit lets build up past the last ledger seal before it seals
    /// (`ledger::seal_due`); `None` leaves sealing to the operator tools.
    pub seal_every: Option<i64>,
}

impl LineageConfig {
    /// Whether `qualified_aggregate` is mirrored into the era-shaped head
    /// snapshots.
    pub fn mirrors(&self, qualified_aggregate: &str) -> bool {
        self.mirrored
            .as_ref()
            .is_none_or(|capable| capable.contains(qualified_aggregate))
    }
}

// `Naming.snake` is the one shared port (rust/codegen/src/hecks_naming.rs); the host reaches it
// through here so both runtimes derive the same storage names.
pub use crate::hecks_naming::snake;

/// `aggregate.storage_name` ported from ir/aggregate.rb — demodulizes a
/// qualified name like `"Banking::Customer"` to `"Customer"` before snaking it.
pub fn storage_name(qualified_aggregate: &str) -> String {
    let short = qualified_aggregate
        .rsplit("::")
        .next()
        .unwrap_or(qualified_aggregate);
    snake(short)
}

pub fn journal_table(domain: &str) -> String {
    format!("hecks_journal_{}", snake(domain))
}

/// Postgres's NAMEDATALEN-1 limit — an identifier over this length is
/// silently truncated, never refused, so two overlong names sharing a
/// prefix would otherwise collide.
pub const POSTGRES_IDENTIFIER_LIMIT: usize = 63;

/// Same algorithm as `Lineage#qualified_name` (lineage.rb): 63-byte limit,
/// SHA256 suffix over the full name, a cut that never splits a character, domain-qualified so
/// two domains' storage names can't collide (ADR 0059).
pub fn qualified_name(domain: &str, suffix: &str) -> String {
    let full = format!("{}_{}", snake(domain), suffix);
    if full.len() <= POSTGRES_IDENTIFIER_LIMIT {
        return full;
    }

    let digest = format!("{:x}", Sha256::digest(full.as_bytes()));
    let digest = &digest[0..8];
    let mut keep = POSTGRES_IDENTIFIER_LIMIT - digest.len() - 1;
    // Cut at the longest prefix of whole characters that fits, as the Ruby side does.
    while !full.is_char_boundary(keep) {
        keep -= 1;
    }
    format!("{}_{}", &full[0..keep], digest)
}

/// The era-shaped snapshot table of one aggregate's head at `era`.
pub fn head_snapshot_table(domain: &str, qualified_aggregate: &str, era: i32) -> String {
    qualified_name(
        domain,
        &format!(
            "{}_head_snapshot_{}",
            storage_name(qualified_aggregate),
            era
        ),
    )
}

/// One `MutationRecord` from the kernel's JSON output, parsed generically
/// since rust/host never links the kernel crate directly (ADR 0012).
pub struct Mutation<'a> {
    pub aggregate: &'a str,
    pub id: &'a str,
    pub operation: &'a str,
    pub state: &'a serde_json::Value,
}

// Not wired into dispatch::handle's replay seed — overlaying translated
// head state onto raw replayed steps would cause false "AlreadyExists" refusals.
/// The head view of one aggregate, qualified by its domain (ADR 0059).
pub fn head_view(domain: &str, storage_name: &str) -> String {
    qualified_name(domain, &format!("{storage_name}_head"))
}

/// One row of `hecks_eras`, mirroring era_store.rb's `eras` shape.
#[derive(Debug, Clone)]
pub struct HeldEra {
    pub ordinal: i32,
    pub label: Option<String>,
    pub watermark: Option<i64>,
}
