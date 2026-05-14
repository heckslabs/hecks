//! [antibody-exempt: rust/src/run_statusline/ — module of the Statuslinen//!  runner ; see mod.rs for the full kernel-floor rationale. Retiresn//!  with mod.rs under i78 when the specializer regenerates from an//!  meta-shape.]n//!n//! Multi-inbox renderer — discovers queued markdown cards across the
//! five registered project inboxes, returns a compact `init:count`
//! listing for the awake statusline.
//!
//! Hard-coded registry (`INBOXES`) maps two-letter initials to
//! `$HOME`-relative inbox paths. Entries with zero queued cards are
//! omitted from the output so the line stays tight ; an empty result
//! means everything is at zero and the caller should drop the
//! envelope segment entirely.
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
pub(super) const INBOXES: &[(&str, &str)] = &[
    ("gl", "Projects/hecks/hecks_conception/inbox"),
    ("pi", "Projects/pigeoncoop/inbox"),
    ("bb", "Projects/bin-buddy/inbox"),
    ("em", "Projects/emaho/inbox"),
    ("hn", "Projects/hecks_nursury/inbox"),
    ("op", "Projects/opt-website/inbox"),
];

/// Walk INBOXES, count queued cards under `$HOME/<rel>` for each.
/// Render entries with count > 0 as `init:count`, space-joined ;
/// entries with count == 0 are omitted so the listing stays compact.
pub(super) fn render_inbox_list() -> String {
    let home = match env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => return String::new(),
    };
    let mut parts: Vec<String> = Vec::new();
    for (init, rel) in INBOXES {
        let count = count_md_inbox_queued(&home.join(rel));
        if count > 0 {
            parts.push(format!("{}:{}", init, count));
        }
    }
    parts.join(" ")
}

/// Count `*.md` cards in a markdown inbox whose YAML frontmatter has
/// `status: queued`. Cheap line-prefix match — no full YAML dep.
pub(super) fn count_md_inbox_queued(inbox_dir: &Path) -> i64 {
    if !inbox_dir.is_dir() { return 0; }
    let mut count: i64 = 0;
    if let Ok(entries) = std::fs::read_dir(inbox_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |e| e == "md") {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    if md_status_is_queued(&text) {
                        count += 1;
                    }
                }
            }
        }
    }
    count
}

fn md_status_is_queued(text: &str) -> bool {
    let body = match text.strip_prefix("---\n") {
        Some(b) => b,
        None => return false,
    };
    let end = match body.find("\n---\n") {
        Some(e) => e,
        None => return false,
    };
    body[..end].lines().any(|l| l.trim() == "status: queued")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md_status_is_queued_recognises_frontmatter() {
        assert!(md_status_is_queued("---\nstatus: queued\nref: x\n---\nbody"));
        assert!(!md_status_is_queued("---\nstatus: closed\nref: x\n---\nbody"));
        assert!(!md_status_is_queued("no frontmatter at all"));
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
        std::fs::write(gl.join("a.md"), "---\nstatus: queued\n---\nbody").unwrap();
        std::fs::write(gl.join("b.md"), "---\nstatus: closed\n---\nbody").unwrap();
        std::env::set_var("HOME", &tmp);

        let out = render_inbox_list();
        assert!(out.contains("gl:1"), "got: {}", out);
        assert!(!out.contains("pi:"), "empty inbox must be omitted: {}", out);

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
