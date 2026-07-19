# FOLLOWUP — lift `load_all_hecksagons` into corpus_loader (2026-07-02)

## Why
Descoped from the boot-establishment keystone (Chris's call at review). The
keystone's completion runtime (`rust/src/run_boot/complete.rs`) boots with the
boot hecksagons alone — establishment POLICIES register + fire on `BootCompleted`
with no hecksagon at all, and zero establishment EFFECTS (which would need a
corpus adapter) exist today. So the completion path is correct + latent-wired
now ; lifting the loader is pure future-proofing for when establishment effects
land.

## The lift
`load_all_hecksagons(agg_dir) -> Vec<Hecksagon>` currently lives cli-only in
`rust/cli/src/main.rs` (~line 3191). It is NOT small:
- ~100 LOC (recursive walk + sibling-repo fan-out + world-sqlite fill + verbose trace) ;
- depends on `find_world_sqlite_path` (also cli-local) ;
- has ~24 call sites in main.rs.

Move it to `rust/src/corpus_loader/mod.rs` as `pub fn` (its natural home, beside
`load_combined_domain`), handle/relocate `find_world_sqlite_path`, update every
caller, and verify cli behaviour is byte-identical (the walk order + dedupe must
not drift). Then `run_boot/complete.rs::complete_boot` can pass the full corpus
hecksagons to the completion runtime instead of the boot hex, so establishment
effects wire their adapters.

## Not urgent
No establishment effect exists to need it. File it, do it as its own focused
change with its own parity check — do not smuggle it into an unrelated commit.
