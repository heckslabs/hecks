//! Holds the kernel's dependency boundary: this crate ships as the WASM and native kernel, and
//! depends on the expression evaluator crate (`hecks_expr`) and nothing else, and that crate depends
//! on `regex` alone (docs/implemented/decisions/0012-wasm-via-wasi-stdio.md, with `regex` the one
//! exception). Transport, storage and the AWS SDK belong to `rust/host`, never here.

/// The crate names under `[dependencies]` in `manifest`, read up to the next `[` section.
fn dependency_names(manifest: &str) -> Vec<String> {
    manifest
        .lines()
        .skip_while(|line| line.trim() != "[dependencies]")
        .skip(1)
        .take_while(|line| !line.trim_start().starts_with('['))
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .filter_map(|line| line.split('=').next())
        .map(|name| name.trim().to_string())
        .collect()
}

#[test]
fn the_kernel_depends_on_the_expression_crate_alone() {
    let names = dependency_names(include_str!("../Cargo.toml"));
    assert_eq!(
        names,
        vec!["hecks_expr".to_string()],
        "rust/Cargo.toml's [dependencies] must be exactly `hecks_expr` (ADR 0012, \
         docs/implemented/decisions/0012-wasm-via-wasi-stdio.md): the kernel ships as WASM and \
         stays free of transport and storage crates, which belong in rust/host"
    );
}

#[test]
fn the_expression_crate_depends_on_regex_alone() {
    let names = dependency_names(include_str!("../expr/Cargo.toml"));
    assert_eq!(
        names,
        vec!["regex".to_string()],
        "rust/expr/Cargo.toml's [dependencies] must be exactly `regex`, the one exception to the \
         no-dependency rule (ADR 0012): the evaluator ships inside the WASM kernel"
    );
}

#[test]
fn dependency_names_stops_at_the_next_section() {
    let manifest = "[package]\nname = \"x\"\n[dependencies]\n# a note\nregex = \"1\"\n\n\
                    [lib]\npath = \"src/lib.rs\"\n";
    assert_eq!(dependency_names(manifest), vec!["regex".to_string()]);
}
