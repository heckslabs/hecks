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
];

const PRIVATE_STORES: &[&str] = &[
    "mood", "feeling", "dream_state", "impulse", "craving", "daydream",
    "pulse", "spend", "circuit_breaker",
];

#[derive(Debug, Clone, Default)]
pub struct Classification {
    pub linked: Vec<String>,
    pub private_: Vec<String>,
    pub unclassified: Vec<String>,
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
