//! [antibody-exempt: rust/src/run_statusline/ — module of the Statusline
//!  runner ; see mod.rs for the full kernel-floor rationale. Retires
//!  with mod.rs under i78 when the specializer regenerates from a
//!  meta-shape.]
//!
//! Multi-inbox renderer : discovers active (not-done-yet) markdown cards
//! across the registered project inboxes, returns a compact `init:count`
//! listing for the awake statusline.
//!
//! Hard-coded registry (`INBOXES`) maps two-letter initials to
//! `$HOME`-relative inbox paths. Entries with zero active cards are
//! omitted from the output so the line stays tight ; an empty result
//! means everything is at zero and the caller should drop the
//! envelope segment entirely.
//!
//! A card is "active" when its YAML frontmatter has a `status` line
//! whose value is NOT one of `closed`, `done`, `archived`. Cards
//! without frontmatter (READMEs, scratch files) are not counted.
//!
//! Example output : `gl:134 pi:51 bb:8`.

use std::env;
use std::path::{Path, PathBuf};

/// Initial → `$HOME`-relative inbox path. Order drives render order.
///   gl — global (hecks_conception, the framework inbox)
///   pi — pigeoncoop
///   bb — bin-buddy
///   em — emaho
///   hn — hecks_nursury
///   op — opt-website
///
/// Both repos that have an `inbox/` → `main.inbox/` rename in progress
/// (emaho, opt-website) already expose `inbox/` as a working path
/// (symlink or sibling). Keeping the registry pointed at `inbox/` lets
/// either layout resolve.
pub(super) const INBOXES: &[(&str, &str)] = &[
    ("gl", "Projects/hecks/hecks_conception/inbox"),
    ("pi", "Projects/pigeoncoop/inbox"),
    ("bb", "Projects/bin-buddy/inbox"),
    ("em", "Projects/emaho/inbox"),
    ("hn", "Projects/hecks_nursury/inbox"),
    ("op", "Projects/opt-website/inbox"),
];

/// Walk INBOXES, count active cards under `$HOME/<rel>` for each.
/// Render entries with count > 0 as `init:count`, space-joined ;
/// entries with count == 0 are omitted so the listing stays compact.
pub(super) fn render_inbox_list() -> String {
    let home = match env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => return String::new(),
    };
    let mut parts: Vec<String> = Vec::new();
    for (init, rel) in INBOXES {
        let count = count_md_inbox_active(&home.join(rel));
        if count > 0 {
            parts.push(format!("{}:{}", init, count));
        }
    }
    parts.join(" ")
}

/// Count `*.md` cards in a markdown inbox whose YAML frontmatter has a
/// `status` that is NOT one of `closed`, `done`, `archived`. Cheap
/// line-prefix match : no full YAML dep.
pub(super) fn count_md_inbox_active(inbox_dir: &Path) -> i64 {
    if !inbox_dir.is_dir() { return 0; }
    let mut count: i64 = 0;
    if let Ok(entries) = std::fs::read_dir(inbox_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |e| e == "md") {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    if md_status_is_active(&text) {
                        count += 1;
                    }
                }
            }
        }
    }
    count
}

fn md_status_is_active(text: &str) -> bool {
    let body = match text.strip_prefix("---\n") {
        Some(b) => b,
        None => return false,
    };
    let end = match body.find("\n---\n") {
        Some(e) => e,
        None => return false,
    };
    for line in body[..end].lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("status:") {
            let status = rest.trim();
            return !matches!(status, "closed" | "done" | "archived");
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md_status_is_active_recognises_active_statuses() {
        assert!(md_status_is_active("---\nstatus: open\nref: x\n---\nbody"));
        assert!(md_status_is_active("---\nstatus: queued\nref: x\n---\nbody"));
        assert!(md_status_is_active("---\nstatus: in-progress\nref: x\n---\nbody"));
        assert!(md_status_is_active("---\nstatus: blocked\nref: x\n---\nbody"));
        assert!(md_status_is_active("---\nstatus: deferred\nref: x\n---\nbody"));
    }

    #[test]
    fn md_status_is_active_excludes_done_statuses() {
        assert!(!md_status_is_active("---\nstatus: closed\nref: x\n---\nbody"));
        assert!(!md_status_is_active("---\nstatus: done\nref: x\n---\nbody"));
        assert!(!md_status_is_active("---\nstatus: archived\nref: x\n---\nbody"));
    }

    #[test]
    fn md_status_is_active_skips_cards_without_frontmatter() {
        assert!(!md_status_is_active("no frontmatter at all"));
        assert!(!md_status_is_active("---\nref: x\n---\nbody"));
    }

    #[test]
    fn render_inbox_list_skips_empty_inboxes() {
        let tmp = std::env::temp_dir().join(format!(
            "statusline_inbox_render_{}", std::process::id()
        ));
        let gl = tmp.join("Projects/hecks/hecks_conception/inbox");
        let pi = tmp.join("Projects/pigeoncoop/inbox");
        std::fs::create_dir_all(&gl).unwrap();
        std::fs::create_dir_all(&pi).unwrap();
        std::fs::write(gl.join("a.md"), "---\nstatus: open\n---\nbody").unwrap();
        std::fs::write(gl.join("b.md"), "---\nstatus: closed\n---\nbody").unwrap();
        std::env::set_var("HOME", &tmp);

        let out = render_inbox_list();
        assert!(out.contains("gl:1"), "got: {}", out);
        assert!(!out.contains("pi:"), "empty inbox must be omitted: {}", out);

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
