//! Behaviors fixtures auto-loader (i4 gap 8).
//!
//! The behaviors runner finds a sibling `.fixtures` file for a given
//! `.behaviors` path and applies its records into a fresh runtime
//! before each test runs. Cross-aggregate cascades that read state
//! seeded by another aggregate's fixtures no longer need explicit
//! `setup` chains in every test.
//!
//! Discovery (in order):
//!   1. `<dir>/<stem>.fixtures`              — flat sibling
//!   2. `<dir>/fixtures/<stem>.fixtures`     — conventional subdir
//!
//! Parity: mirrors `lib/hecks/behaviors/fixtures_loader.rb`. Same
//! discovery rules, same seed convention (ids "1", "2", … in source
//! order), same "first fixture per aggregate wins the in-scope slot".
//!
//! [antibody-exempt: test runner auto-loads fixtures for cross-aggregate
//! cascades (i4 gap 8); retires when behaviors runner ports to
//! bluebook-dispatched form]

use crate::fixtures_ir::FixturesFile;
use crate::fixtures_parser;
use crate::runtime::{AggregateState, Runtime, Value};
use std::collections::HashMap;
use std::path::PathBuf;

/// Returns the absolute path of the fixtures file matching the given
/// `.behaviors` (or `_behavioral_tests.bluebook`) path, or None if
/// nothing matches. Public so the runner can log which file loaded.
pub fn locate_path(behaviors_path: &str) -> Option<String> {
    let p = PathBuf::from(behaviors_path);
    let stem_raw = p.file_stem()?.to_str()?;
    // Strip the `_behavioral_tests` trailer if the caller passed the
    // pre-split-out form (rare — most call sites pass the .behaviors
    // name, whose file_stem is already the domain stem).
    let stem = stem_raw.trim_end_matches("_behavioral_tests");
    let parent = p.parent().map(|q| q.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));

    let candidates = [
        parent.join(format!("{}.fixtures", stem)),
        parent.join("fixtures").join(format!("{}.fixtures", stem)),
    ];
    candidates.iter()
        .find(|c| c.is_file())
        .map(|c| c.to_string_lossy().into_owned())
}

/// Parse a .fixtures file from disk. Returns None on read failure —
/// the runner logs and continues (empty fixtures = old behavior).
pub fn parse_file(path: &str) -> Option<FixturesFile> {
    let source = std::fs::read_to_string(path).ok()?;
    Some(fixtures_parser::parse(&source))
}

/// Convenience: locate + parse. Returns None when no sibling file
/// exists.
pub fn find_for(behaviors_path: &str) -> Option<FixturesFile> {
    let path = locate_path(behaviors_path)?;
    parse_file(&path)
}

/// Seed a fresh runtime with fixture data. Creates one AggregateState
/// per fixture record under sequential integer ids ("1", "2", ...),
/// which matches `pre_seed_singletons`' id convention. The FIRST
/// fixture per aggregate wins the in_scope slot — what references
/// resolve to when a command needs a sibling aggregate's id.
///
/// Returns the in_scope delta so the runner can merge it into its
/// own map (alongside `pre_seed_singletons` results).
pub fn apply(rt: &mut Runtime, fixtures: &FixturesFile) -> HashMap<String, String> {
    let mut in_scope: HashMap<String, String> = HashMap::new();

    // Group fixtures by aggregate so ids are per-aggregate-contiguous,
    // matching the Ruby loader.
    let mut by_agg: HashMap<String, Vec<&crate::ir::Fixture>> = HashMap::new();
    for f in &fixtures.fixtures {
        by_agg.entry(f.aggregate_name.clone()).or_default().push(f);
    }

    for (agg_name, list) in by_agg {
        // Fixture references an aggregate the domain doesn't define —
        // skip silently; the source bluebook/fixtures file authors will
        // see zero seed effect and can fix the mismatch.
        let Some(repo) = rt.repositories.get_mut(&agg_name) else { continue };
        for (i, fix) in list.iter().enumerate() {
            let id = (i + 1).to_string();
            let mut state = AggregateState::new(&id);
            for (key, raw) in &fix.attributes {
                state.set(key, parse_fixture_value(raw));
            }
            repo.save(state);
            in_scope.entry(agg_name.clone()).or_insert_with(|| id.clone());
        }
    }

    in_scope
}

/// Parse a fixture attribute value from its source-token form. Same
/// shape as behaviors_runner::parse_value but extended for the list
/// literals that .fixtures files commonly carry (`linked: ["a","b"]`).
fn parse_fixture_value(raw: &str) -> Value {
    let s = raw.trim();
    if s.starts_with('[') && s.ends_with(']') {
        let inner = &s[1..s.len() - 1];
        let items: Vec<Value> = inner.split(',')
            .map(|p| p.trim().trim_matches('"').trim_matches('\''))
            .filter(|p| !p.is_empty())
            .map(|p| Value::Str(p.to_string()))
            .collect();
        return Value::List(items);
    }
    if let Ok(n) = s.parse::<i64>() { return Value::Int(n); }
    if s == "true"  { return Value::Bool(true); }
    if s == "false" { return Value::Bool(false); }
    Value::Str(s.to_string())
}
