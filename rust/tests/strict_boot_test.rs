//! Interim host-language strictness: the Rust parser is permissive by
//! design and half-reads what Ruby refuses. The detectable class — a
//! near-miss block keyword the parser skipped — refuses at boot rather
//! than booting under a domain definition the reference implementation
//! would reject. Partial, by admission: an entirely alien construct
//! still skips silently; full load/refuse parity awaits the
//! specializer (named in the gaps ledger).

use std::fs;
use storehouse::dispatcher::Runtime;

#[test]
fn a_near_miss_block_keyword_refuses_at_boot_instead_of_half_reading() {
    let root = std::env::temp_dir().join(format!("hecks-strict-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let bluebook_dir = root.join("bluebook");
    fs::create_dir_all(&bluebook_dir).unwrap();
    // `lifecycl` — Ruby refuses this outright; the permissive parser
    // used to skip the whole block, silently shipping an aggregate
    // without its lifecycle.
    fs::write(
        bluebook_dir.join("typo.bluebook"),
        "Hecks.bluebook \"Typo\" do\n  aggregate \"Sketch\" do\n    attribute :cost, Money\n\n    lifecycl :status, default: \"open\" do\n      transition \"Close\" => \"closed\"\n    end\n\n    value_object \"Money\" do\n      attribute :cents, Integer\n    end\n  end\nend\n",
    )
    .unwrap();
    fs::write(
        bluebook_dir.join("typo.world"),
        "Hecks.world \"Typo\" do\n  realm \"Examples\"\n  persisted_by(\"Memory\")\nend\n",
    )
    .unwrap();

    let refusal = Runtime::boot(bluebook_dir.join("typo.bluebook")).err().expect("the typo must refuse");
    assert_eq!(
        refusal,
        "cannot boot Typo::Sketch: this runtime could not read 'lifecycl' (did you mean 'lifecycle'?) — \
         a construct it cannot read refuses rather than half-reads; \
         host-language strictness is partial until the specializer"
    );

    let _ = fs::remove_dir_all(&root);
}
