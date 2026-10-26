//! Coverage-guided differential target: the host's in-memory journal store against its Postgres one.
//!
//! libFuzzer decodes its bytes into a typed script of Banking commands (`arbitrary`), the script
//! runs against the in-memory store, and Postgres is asked only about scripts whose structure is
//! new. See `rust_host_fuzz::equivalence` for the rules and `rust_host_fuzz::footprint` for the memo.
//!
//! Needs the compiled kernel at `rust/dist/banking.wasm` (or `HECKS_FUZZ_WASM`). With
//! `HECKS_FUZZ_PG` unset only the in-memory store runs, which still checks the commit clause.
//!
//! ```sh
//! cd rust/host
//! createdb hecks_fuzz
//! HECKS_FUZZ_PG="host=localhost user=$USER dbname=hecks_fuzz" \
//!   cargo +nightly fuzz run postgres_equivalence -- -max_len=1024 -timeout=30
//! ```
#![no_main]

use libfuzzer_sys::fuzz_target;
use rust_host_fuzz::equivalence;
use rust_host_fuzz::ops::Script;

fuzz_target!(init: equivalence::warm(), |script: Script| {
    equivalence::check(&script);
});
