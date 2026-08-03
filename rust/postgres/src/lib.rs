mod postgres_repository;

pub use postgres_repository::{postgres_factory, register, PostgresRepository};

// `shape_of`/`shape_of_checked` used to live here — parse-and-project a
// held era's text, for a legacy-row backfill and a cosmetic-vs-real
// tamper-diagnosis message. Both call sites are gone now: the backfill
// closed with a one-time migration (`bin/backfill_era_projections`,
// reusing Ruby's own already-existing incidental backfill rather than
// computing one at Rust boot time), and the diagnosis message turned out
// to be a pure quality-of-message nicety, not a safety property — the
// digest check that DETECTS tampering never depended on either, so
// dropping both takes this crate's parser dependency to genuinely zero,
// not merely gated.
