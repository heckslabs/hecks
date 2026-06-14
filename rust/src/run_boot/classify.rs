//! Phase 3 — ClassifyStores
//!
//! Walks `<info_dir>/*.heki`, classifies each filename as :
//!   - linked       : flows through the psychic link to the paired being
//!   - private      : inner life, this being only
//!   - unclassified : unknown — surfaced so we make explicit choices
//!                    instead of forgetting
//!
//! The two constant lists below are ported verbatim from boot_miette.sh
//! (the "psychic-link contract"). Keeping them in this module is the
//! transitional shape : the long-term home is per-aggregate
//! `psychic_link: true|false` declarations in the bluebook itself, so
//! the boundary lives in the domain model. See : the boot.bluebook
//! ClassifyStores description's "structural follow-up" note.

use std::fs;
use std::path::Path;

const LINKED_STORES: &[&str] = &[
    "memory", "awareness", "census", "conversation", "working_memory",
    "reflection", "synapse", "signal", "signal_somatic", "focus",
    "concentration", "deliberation", "heartbeat", "subconscious",
    "domain_index", "arc", "consciousness", "discipline", "metabolic_rate",
    "musing", "conflict_monitor", "run_log", "inbox", "tick", "announcement",
    "attention", "claude_assist", "consolidation", "dream_interpretation",
    "dream_seed", "dream_signal", "encoding", "gate", "generosity", "gut",
    "HarmonyDomain", "intention", "interpretation", "lucid_dream",
    "lucid_monitor", "monitor", "musing_archive", "musing_mint", "nerve",
    "nursery", "perception", "persona", "proposal", "proprioception",
    "self_image", "self_model", "sensation", "session", "shared_dream_space",
    "signal_consolidation", "speech", "training_pair", "wake_mood", "witness",
    "bodhisattva_vow", "character", "creator_auth", "remains", "store",
    "heart", "breath", "circadian", "ultradian", "sleep_cycle",
    "wake_ritual",
];

const PRIVATE_STORES: &[&str] = &[
    "mood", "feeling", "dream_state", "impulse", "craving", "daydream",
    "pulse", "spend", "circuit_breaker",
];

/// Stores recognised as known-retired — pre-convention orphans whose
/// rows survive in info_dir but no current writer targets them. The
/// classifier silently absorbs these so the unclassified warning
/// stays focused on genuinely-new stores that need an explicit
/// classification call. Adding to this list is an explicit choice
/// that the orphan is acknowledged and out of the way ; the rows
/// themselves stay in place for archaeology until someone retires
/// the file in its origin repo.
///
/// `item` — pre-i142 inbox naming. The Inbox aggregate originally
/// stored rows in `item.heki` ("an item" being the colloquial name
/// for one inbox row). When the convention settled on heki-file-
/// per-aggregate (one heki named after the aggregate, the rows
/// being the aggregate's records), the canonical name became
/// `inbox.heki`. Two debugging rows survive in `item.heki` in the
/// miette-state repo (i997 "abs path trace", i998 "HECKS_INFO
/// trace" — April 28 path-resolution debugging).
const RETIRED_STORES: &[&str] = &[
    "item",
    // i728 G3 — non-aggregate stores with no live domain behind them, classified
    // so the persistence-map's `unknown` set reaches zero ("everything that
    // writes to information/ is accounted for"). Two kinds :
    //   dead framework/daemon stores (no current writer) :
    "enforcer",                        // renamed → macrophage (pre-rename orphan)
    "tools",                           // dead flat Tools store (pre 5-category split)
    "antibody_exemption_macrophage",   // stale macrophage check state, no writer
    "bluebook_first_macrophage",       // stale macrophage check state, no writer
    "calling_strategy",                // stale, no writer
    "domain_visualizer",               // stale, no writer
    //   test-leak artifacts (rows are stale leaks ; live writers now isolate to
    //   a tempdir via HECKS_INFO so they no longer reach the live store) :
    "hello",                           // examples/executable hello integration test
    "note",                            // run_script / query_step test fixtures
    "dispatch",                        // storehouse-mcp dispatch render test fixture
];

#[derive(Debug, Clone, Default)]
pub struct Classification {
    pub linked: Vec<String>,
    pub private_: Vec<String>,
    pub unclassified: Vec<String>,
}

/// Classify a store stem by NAME against the boundary lists (i728 G3). The
/// persistence-map uses this to ACCOUNT FOR non-aggregate writers — stores
/// under information/ with no aggregate behind them (process-manager instances,
/// daemon/direct heki writes). Returns the boundary category ; `"unknown"` is
/// the genuinely-unaccounted set the persistence verifier drives to zero, so the
/// assertion is "everything that writes to information/ is accounted for", not
/// merely "every aggregate is".
pub fn classify_name(stem: &str) -> &'static str {
    if RETIRED_STORES.contains(&stem) {
        "retired"
    } else if PRIVATE_STORES.contains(&stem) {
        "private"
    } else if LINKED_STORES.contains(&stem) {
        "linked"
    } else {
        "unknown"
    }
}

pub fn classify(info_dir: &str) -> Classification {
    let mut out = Classification::default();
    let dir = Path::new(info_dir);
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return out,
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.is_file() { continue; }
        if p.extension().map(|e| e != "heki").unwrap_or(true) { continue; }
        let stem = match p.file_stem().and_then(|s| s.to_str()) {
            Some(s) => s,
            None => continue,
        };
        // Skip dotfiles like `.mindstream.pid` (already filtered by ext)
        // and hidden heki names like `.statusline_heart_phase`.
        if stem.starts_with('.') { continue; }

        // Retired stores are silently absorbed — neither classified
        // as a live boundary nor flagged unclassified.
        if RETIRED_STORES.contains(&stem) { continue; }

        if PRIVATE_STORES.contains(&stem) {
            out.private_.push(stem.to_string());
        } else if LINKED_STORES.contains(&stem) {
            out.linked.push(stem.to_string());
        } else {
            out.unclassified.push(stem.to_string());
        }
    }
    out.linked.sort();
    out.private_.sort();
    out.unclassified.sort();
    out
}
