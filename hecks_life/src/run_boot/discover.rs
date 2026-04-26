//! Phase 1 + 2 — DiscoverOrgans + WriteCensus
//!
//! Walks `aggregates/` and `capabilities/` under the conception dir,
//! parses each .bluebook into IR, sums up :
//!   - organs        : .bluebook files in aggregates/
//!   - capabilities  : .bluebook files under capabilities/
//!   - aggregates    : sum of `aggregates[]` across all bluebooks
//!   - nerves        : policies whose `target_domain` is set (cross-
//!                     domain edges, the "nerve" metaphor)
//!   - vows          : 0 today — the parser doesn't extract `vow "Name" do`
//!                     blocks. The shell hand-curated this number.
//!                     Gap : add `Domain.vows` field + parser support.
//!
//! WriteCensus then upserts these counts into `<info>/census.heki` so
//! anything reading the heki sees the same numbers the runner printed.

use crate::heki;
use crate::parser;

use std::path::Path;

/// Tally of bluebook objects discovered across the conception tree.
#[derive(Debug, Clone, Default)]
pub struct OrganCounts {
    pub organs: usize,
    pub capabilities: usize,
    pub aggregates: usize,
    pub nerves: usize,
    pub vows: usize,
}

pub fn count_organs(conception_dir: &Path) -> OrganCounts {
    let agg_dir = conception_dir.join("aggregates");
    let cap_dir = conception_dir.join("capabilities");

    let organs = count_top_level_bluebooks(&agg_dir);
    let capabilities = count_recursive_bluebooks(&cap_dir);

    let mut aggregates = 0usize;
    let mut nerves = 0usize;
    let mut vows = 0usize; // see module docs

    if let Ok(entries) = std::fs::read_dir(&agg_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                if let Ok(src) = std::fs::read_to_string(&p) {
                    let domain = parser::parse(&src);
                    aggregates += domain.aggregates.len();
                    nerves += domain.policies.iter()
                        .filter(|p| p.target_domain.as_ref()
                            .map(|s| !s.is_empty()).unwrap_or(false))
                        .count();
                }
            }
        }
    }

    OrganCounts { organs, capabilities, aggregates, nerves, vows }
}

/// Upsert the discovered counts into `<info_dir>/census.heki`. Mirrors
/// the shell's `hecks-life heki upsert census.heki id=1 ...` line.
pub fn write_census(info_dir: &str, counts: &OrganCounts) -> Result<(), String> {
    let path = format!("{}/census.heki", info_dir.trim_end_matches('/'));
    let mut rec = heki::Record::new();
    rec.insert("id".into(),                  serde_json::Value::String("1".into()));
    rec.insert("total_domains".into(),       n(counts.organs));
    rec.insert("total_aggregates".into(),    n(counts.aggregates));
    rec.insert("total_capabilities".into(),  n(counts.capabilities));
    rec.insert("total_nerves".into(),        n(counts.nerves));
    rec.insert("total_vows".into(),          n(counts.vows));
    let _ = heki::upsert(&path, &rec)?;
    Ok(())
}

fn n(v: usize) -> serde_json::Value {
    serde_json::Value::Number(serde_json::Number::from(v as u64))
}

fn count_top_level_bluebooks(dir: &Path) -> usize {
    if !dir.is_dir() { return 0; }
    let mut n = 0;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file() && p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                n += 1;
            }
        }
    }
    n
}

fn count_recursive_bluebooks(dir: &Path) -> usize {
    if !dir.is_dir() { return 0; }
    let mut n = 0;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                n += count_recursive_bluebooks(&p);
            } else if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                n += 1;
            }
        }
    }
    n
}
