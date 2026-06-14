//! i728 Phase-B — the persistence-map projection's correctness contract.
//!
//! Pins the two truths the live cross-check caught the hard way :
//!   1. SOURCE labels — unwired → default / declared :X / CONFLICT when the
//!      same context name carries divergent adapters across the load-set
//!      (the real Inbox case : conception=:heki + tools/=:memory).
//!   2. ORPHAN detection — normalises case on both sides (a legacy CamelCase
//!      store dir is the SAME store the snake-cased aggregate writes to, so it
//!      is NOT an orphan), and surfaces process-manager instance stores (the
//!      G3 universe — live writers that are not aggregates).

use storehouse::ir::{Aggregate, Domain};
use storehouse::run_persistence_map::{build_rows, find_orphans};

fn agg(name: &str, ctx: &str) -> Aggregate {
    Aggregate {
        name: name.into(),
        description: None,
        context: Some(ctx.into()),
        category: None,
        identified_by: None,
        attributes: vec![],
        factories: vec![],
        commands: vec![],
        queries: vec![],
        value_objects: vec![],
        entities: vec![],
        references: vec![],
        lifecycle: None,
        invariants: vec![],
        views: vec![],
    }
}

fn dom(aggs: Vec<Aggregate>) -> Domain {
    Domain {
        name: "T".into(),
        category: None,
        vision: None,
        aggregates: aggs,
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        process_managers: vec![],
        cadences: vec![],
        block_grammars: vec![],
    }
}

fn hex(src: &str) -> storehouse::hecksagon_ir::Hecksagon {
    storehouse::hecksagon_parser::parse(src)
}

#[test]
fn source_labels_unwired_declared_and_conflict() {
    let domain = dom(vec![agg("Inbox", "Inbox"), agg("Foo", "Foo"), agg("Bar", "Bar")]);
    let hecksagons = vec![
        hex("Hecks.hecksagon \"Inbox\" do\n  adapter :heki\nend"),
        // Same context name, divergent adapter — the collision must surface,
        // not be silently resolved by last-wins.
        hex("Hecks.hecksagon \"Inbox\" do\n  adapter :memory\nend"),
        hex("Hecks.hecksagon \"Foo\" do\n  adapter :memory\nend"),
        // Bar : no hecksagon names it → unwired.
    ];
    let rows = build_rows(&domain, &hecksagons, "/no/such/info/dir");
    let src = |fqn: &str| {
        rows.iter()
            .find(|r| r.fqn == fqn)
            .unwrap_or_else(|| panic!("row {fqn} missing"))
            .source
            .clone()
    };
    assert_eq!(src("Inbox::Inbox"), "CONFLICT :heki vs :memory");
    assert_eq!(src("Foo::Foo"), "declared :memory");
    assert_eq!(src("Bar::Bar"), "unwired → default");
}

#[test]
fn classify_name_accounts_for_boundary_categories() {
    use storehouse::run_boot::classify::classify_name;
    // Known boundary stores are accounted for ; an unknown store is the
    // genuinely-UNACCOUNTED set the persistence verifier drives to zero (G3).
    assert_eq!(classify_name("subconscious"), "linked");
    assert_eq!(classify_name("craving"), "private");
    assert_eq!(classify_name("item"), "retired");
    assert_eq!(classify_name("a_store_no_list_knows"), "unknown");
}

#[test]
fn orphans_normalize_case_and_surface_process_managers() {
    let base = std::env::temp_dir().join(format!("pmap_orphan_test_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).unwrap();
    // Claimed aggregate `Attention` ; its store dir is literally CamelCase on
    // disk (the legacy pre-snake_case casing). Must NOT read as an orphan.
    std::fs::create_dir_all(base.join("Attention")).unwrap();
    std::fs::write(base.join("Attention").join("Attention.heki"), "x").unwrap();
    // A genuine orphan : a live store no aggregate claims.
    std::fs::write(base.join("ghost.heki"), "x").unwrap();
    // A process-manager instance store — the G3 universe.
    std::fs::create_dir_all(base.join("process_managers")).unwrap();
    std::fs::write(base.join("process_managers").join("pm1.heki"), "x").unwrap();

    let domain = dom(vec![agg("Attention", "Attention")]);
    let orphans = find_orphans(&domain, &base.to_string_lossy());

    assert!(
        !orphans.iter().any(|o| o.eq_ignore_ascii_case("attention")),
        "CamelCase store of a claimed aggregate must not be an orphan: {orphans:?}"
    );
    assert!(orphans.contains(&"ghost".to_string()), "ghost should be orphan: {orphans:?}");
    assert!(
        orphans.contains(&"process_managers/pm1".to_string()),
        "process-manager instance must surface (G3): {orphans:?}"
    );

    let _ = std::fs::remove_dir_all(&base);
}
