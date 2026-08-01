//! A DECLARED-ephemeral domain iterates freely: the world file says, in
//! versioned text, that this data is disposable — so the era gate holds
//! nothing and refuses nothing. Without the declaration, the same drift
//! refuses loudly. Twin of the Ruby examples in spec/era_check_spec.rb.

use std::fs;
use std::path::PathBuf;
use storehouse::dispatcher::Runtime;

const V1: &str = "Hecks.bluebook \"Iter\" do\n  aggregate \"Sketch\" do\n    attribute :cost, Money\n\n    value_object \"Money\" do\n      attribute :cents, Integer\n    end\n  end\nend\n";
const V2: &str = "Hecks.bluebook \"Iter\" do\n  aggregate \"Sketch\" do\n    attribute :amount, Money\n\n    value_object \"Money\" do\n      attribute :cents, Integer\n    end\n  end\nend\n";

fn stage(label: &str, ephemeral: bool) -> PathBuf {
    let root = std::env::temp_dir().join(format!("hecks-ephemeral-{label}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let bluebook_dir = root.join("bluebook");
    fs::create_dir_all(&bluebook_dir).unwrap();
    fs::write(bluebook_dir.join("iter.bluebook"), V1).unwrap();
    let eras_line = if ephemeral { "    eras \"ephemeral\"\n" } else { "" };
    fs::write(
        bluebook_dir.join("iter.world"),
        format!("Hecks.world \"Iter\" do\n  realm \"Examples\"\n  persisted_by(\"Memory\") do\n{eras_line}  end\nend\n"),
    )
    .unwrap();
    root
}

#[test]
fn a_declared_ephemeral_domain_never_holds_and_never_refuses_drift() {
    let root = stage("free", true);
    let bluebook = root.join("bluebook").join("iter.bluebook");

    Runtime::boot(&bluebook).unwrap();
    assert!(!root.join("data").join("eras").exists(), "an ephemeral domain must hold nothing");

    fs::write(&bluebook, V2).unwrap();
    Runtime::boot(&bluebook).unwrap();

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn the_same_drift_refuses_without_the_declaration() {
    let root = stage("strict", false);
    let bluebook = root.join("bluebook").join("iter.bluebook");

    Runtime::boot(&bluebook).unwrap();
    fs::write(&bluebook, V2).unwrap();
    let refusal = Runtime::boot(&bluebook).err().expect("drift must refuse without ephemeral");
    assert_eq!(
        refusal,
        "cannot boot Sketch: the shape changed (era 2) and Memory cannot translate — bind Postgres, or reset the data"
    );

    let _ = fs::remove_dir_all(&root);
}
