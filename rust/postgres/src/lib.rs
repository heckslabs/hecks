mod postgres_repository;

pub use postgres_repository::{postgres_factory, register, PostgresRepository};

/// The storage-shape projection of one bluebook source — parse with the
/// core parser, project with the core projection. Shared by the era
/// gate so held texts compare structurally, never by bytes or hashes.
///
/// GATED ON `parser` — the happy path never calls this at all: Ruby's own
/// minting (`lib/hecksagain/adapters/driven/postgres/lineage/
/// {mint_transaction,era_store}.rb`, `era_resolver.rb`) always stores a
/// precomputed `held_projection` alongside a new era row, computed from
/// the already-booted domain, never from re-parsed text. This is only
/// ever reached for a row that PREDATES that column (a one-time-per-row
/// legacy backfill, cached forever after — see `postgres_repository.rs::
/// eras()`) or to distinguish a cosmetic tamper-edit from a real one in a
/// refusal message. Neither needs to exist in a binary that only ever
/// boots domains already compiled in.
#[cfg(feature = "parser")]
pub fn shape_of(source: &str) -> serde_json::Value {
    storehouse::runtime::storage_shape::project(&storehouse::parser::parse(source))
}

/// THE SAME PROJECTION, REFUSABLE — used only where the source may have
/// been TAMPERED WITH, not by the backfill/consistency callers of
/// `shape_of` above, which only ever see text this runtime already trusts.
///
/// `shape_of` never refuses: the core parser is permissive by design (see
/// `runtime::strict_boot`'s own doc comment) and silently drops whatever it
/// cannot read, so a held text edited into a typo — `atribute` for
/// `attribute` — still projects to SOME shape rather than to nothing, and
/// `integrity_refusal` could never reach its generic "held era texts are
/// storage facts" wording the way Ruby's `EraTamper#project` does when
/// `Kernel.eval` raises. `strict_boot::scan` is the one detectable class of
/// that gap — a word at aggregate-body level close enough to a real one to
/// be a near-miss — so checking it first before projecting closes exactly
/// that class, honestly partial the same way `strict_boot` names itself:
/// a genuine syntax error (an unbalanced `end`, an unterminated string) has
/// no detector here yet, only the near-miss keyword case does.
#[cfg(feature = "parser")]
pub fn shape_of_checked(source: &str) -> Option<serde_json::Value> {
    if storehouse::runtime::strict_boot::scan(source).is_some() {
        return None;
    }
    Some(shape_of(source))
}
