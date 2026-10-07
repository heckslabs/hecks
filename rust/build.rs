// Prototype: generate the active domain's module tree into OUT_DIR instead of reading a committed
// rust/src/generated. Cargo reruns this script only when a rerun-if-changed input changes.
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let repo = manifest.parent().unwrap().to_path_buf();

    let feature = std::env::vars()
        .filter_map(|(k, _)| k.strip_prefix("CARGO_FEATURE_").map(str::to_lowercase))
        .next()
        .expect("select a domain feature");
    let domain = ["examples", "qa/stress_domains"]
        .iter()
        .map(|d| repo.join(d).join(&feature))
        .find(|p| p.join("bluebook").is_dir())
        .unwrap_or_else(|| panic!("no domain directory for feature {feature}"));

    // Inputs: the domain's bluebooks, plus the generator crates' sources.
    for dir in [domain.join("bluebook"), manifest.join("codegen/src"), manifest.join("parser/src"), manifest.join("build/src"), repo.join("lib/hecks/language/bluebook")] {
        watch(&dir);
    }
    println!("cargo:rerun-if-changed=build.rs");

    let gen = out.join("generated");
    let status = Command::new("cargo")
        .args(["build", "-q", "--manifest-path"])
        .arg(manifest.join("build/Cargo.toml"))
        .status()
        .unwrap();
    assert!(status.success(), "building hecks-build");
    let _ = std::fs::remove_dir_all(&gen);
    let status = Command::new(manifest.join("build/target/debug/hecks-build"))
        .arg(&domain)
        .args(["--out"])
        .arg(&gen)
        .current_dir(&repo)
        .status()
        .unwrap();
    assert!(status.success(), "hecks-build");

    // Point each `pub mod x;` at its absolute file, since the tree is not under src/.
    let text = std::fs::read_to_string(gen.join("mod.rs")).unwrap();
    let mut spliced = String::new();
    for line in text.lines() {
        if let Some(name) = line.trim().strip_prefix("pub mod ").and_then(|n| n.strip_suffix(';')) {
            spliced.push_str(&format!("#[path = {:?}]\n", gen.join(name).join("mod.rs")));
        }
        spliced.push_str(line);
        spliced.push('\n');
    }
    std::fs::write(out.join("generated_mod.rs"), spliced).unwrap();
}

fn watch(dir: &Path) {
    println!("cargo:rerun-if-changed={}", dir.display());
}
