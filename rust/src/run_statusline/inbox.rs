//! [antibody-exempt: rust/src/run_statusline/ — module of the Statusline
//!  runner ; see mod.rs for the full kernel-floor rationale. Retires
//!  with mod.rs under i78 when the specializer regenerates from a
//!  meta-shape.]
//!
//! Multi-inbox renderer : autoloads self-describing inbox channels and
//! renders a compact `emoji [abbrev:]count` listing for the awake
//! statusline.
//!
//! Decentralised registry (i528) : there is NO central list and no
//! hand-mirrored const. Each inbox that wants to appear drops a
//! `.channel.md` descriptor in its own directory :
//!
//!   ---
//!   abbrev: mi          # optional ; empty => emoji + count only
//!   emoji: BEE
//!   label: MietteAI
//!   ---
//!   free-form notes
//!
//! Discovery walks `$HOME/Projects` (bounded depth, heavy dirs pruned)
//! for `.channel.md` files ; the file's directory IS the inbox. A card
//! is "active" when its YAML frontmatter `status` is NOT one of
//! `closed`, `done`, `archived`. Channels with zero active cards are
//! omitted so the line stays tight.
//!
//! Render order : the abbrev-less channel (the framework inbox) leads,
//! the rest follow alphabetically by abbrev.
//!
//! Replaced the central `inbox.fixtures` InboxChannel registry, which
//! was retired 2026-05-17 : adding a channel is now "drop a
//! `.channel.md`" — no central registry, no lockstep, no drift.

use std::env;
use std::path::{Path, PathBuf};

/// One discovered channel : render abbrev (may be empty), emoji, and
/// active-card count.
struct Channel {
    abbrev: String,
    emoji: String,
    count: i64,
}

/// Directory names never worth descending into when hunting descriptors.
const PRUNE: &[&str] = &[
    ".git", "node_modules", "target", "vendor", ".wrangler",
    "dist", "build", ".next", "coverage", ".venv",
];

const MAX_DEPTH: usize = 4;

/// Walk `$HOME/Projects`, collect every directory holding a
/// `.channel.md`, render the non-empty ones (abbrev-less first, then
/// alphabetical by abbrev), space-joined.
pub(super) fn render_inbox_list() -> String {
    let home = match env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => return String::new(),
    };
    let mut channels: Vec<Channel> = Vec::new();
    collect_channels(&home.join("Projects"), 0, &mut channels);

    channels.retain(|c| c.count > 0);
    channels.sort_by(|a, b| {
        (!a.abbrev.is_empty(), &a.abbrev)
            .cmp(&(!b.abbrev.is_empty(), &b.abbrev))
    });

    let parts: Vec<String> = channels
        .iter()
        .map(|c| {
            if c.abbrev.is_empty() {
                format!("{} {}", c.emoji, c.count)
            } else {
                format!("{} {}:{}", c.emoji, c.abbrev, c.count)
            }
        })
        .collect();
    parts.join("  ")
}

fn collect_channels(dir: &Path, depth: usize, out: &mut Vec<Channel>) {
    if depth > MAX_DEPTH || !dir.is_dir() {
        return;
    }
    let desc = dir.join(".channel.md");
    if desc.is_file() {
        if let Some(ch) = parse_channel(&desc, dir) {
            out.push(ch);
        }
    }
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        // Skip symlinked dirs : an `inbox -> main.inbox` alias would
        // otherwise be walked twice (via the link AND the real
        // sibling) and render its channel twice. The real target is
        // still discovered on its own path.
        if entry.file_type().map_or(true, |t| t.is_symlink()) {
            continue;
        }
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n,
            None => continue,
        };
        if name.starts_with('.') || PRUNE.contains(&name) {
            continue;
        }
        collect_channels(&path, depth + 1, out);
    }
}

/// Parse a `.channel.md` descriptor ; count active cards beside it.
fn parse_channel(desc: &Path, dir: &Path) -> Option<Channel> {
    let text = std::fs::read_to_string(desc).ok()?;
    let (mut emoji, mut abbrev) = (String::new(), String::new());
    for line in frontmatter_lines(&text) {
        let t = line.trim();
        if let Some(v) = t.strip_prefix("emoji:") {
            emoji = v.trim().to_string();
        } else if let Some(v) = t.strip_prefix("abbrev:") {
            abbrev = v.trim().to_string();
        }
    }
    if emoji.is_empty() {
        return None;
    }
    Some(Channel { abbrev, emoji, count: count_md_inbox_active(dir) })
}

/// Frontmatter lines of a `---\n … \n---` document (empty if none).
fn frontmatter_lines(text: &str) -> std::str::Lines<'_> {
    let body = text.strip_prefix("---\n").unwrap_or("");
    let end = body.find("\n---").unwrap_or(0);
    body[..end].lines()
}

/// Count `*.md` cards in `inbox_dir` whose YAML frontmatter `status`
/// is NOT one of `closed`, `done`, `archived`. The `.channel.md`
/// descriptor has no `status:` so it never counts itself.
pub(super) fn count_md_inbox_active(inbox_dir: &Path) -> i64 {
    if !inbox_dir.is_dir() {
        return 0;
    }
    let mut count: i64 = 0;
    if let Ok(entries) = std::fs::read_dir(inbox_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |e| e == "md")
                && md_status_is_active(
                    &std::fs::read_to_string(&path).unwrap_or_default(),
                )
            {
                count += 1;
            }
        }
    }
    count
}

fn md_status_is_active(text: &str) -> bool {
    for line in frontmatter_lines(text) {
        if let Some(rest) = line.trim().strip_prefix("status:") {
            return !matches!(rest.trim(), "closed" | "done" | "archived" | "planning");
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
        assert!(md_status_is_active("---\nstatus: blocked\nref: x\n---\nbody"));
    }

    #[test]
    fn md_status_is_active_excludes_done_statuses() {
        assert!(!md_status_is_active("---\nstatus: closed\n---\nbody"));
        assert!(!md_status_is_active("---\nstatus: done\n---\nbody"));
        assert!(!md_status_is_active("---\nstatus: archived\n---\nbody"));
        assert!(!md_status_is_active("no frontmatter at all"));
        assert!(!md_status_is_active("---\nref: x\n---\nbody"));
    }

    #[test]
    fn autoloads_channels_leads_abbrevless_skips_empty() {
        let tmp = std::env::temp_dir()
            .join(format!("sl_inbox_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let gl = tmp.join("Projects/hecks/hecks_conception/inbox");
        let mi = tmp.join("Projects/mietteai/inbox");
        let pi = tmp.join("Projects/pigeoncoop/inbox");
        for d in [&gl, &mi, &pi] {
            std::fs::create_dir_all(d).unwrap();
        }
        std::fs::write(gl.join(".channel.md"),
            "---\nabbrev:\nemoji: GLO\nlabel: Global\n---\nx").unwrap();
        std::fs::write(gl.join("a.md"),
            "---\nstatus: open\n---\nb").unwrap();
        std::fs::write(gl.join("b.md"),
            "---\nstatus: closed\n---\nb").unwrap();
        std::fs::write(mi.join(".channel.md"),
            "---\nabbrev: mi\nemoji: BEE\nlabel: MietteAI\n---\nx").unwrap();
        std::fs::write(mi.join("i1.md"),
            "---\nstatus: open\n---\nb").unwrap();
        std::fs::write(mi.join("i2.md"),
            "---\nstatus: queued\n---\nb").unwrap();
        std::fs::write(pi.join(".channel.md"),
            "---\nabbrev: pi\nemoji: DOV\nlabel: Pigeoncoop\n---\nx").unwrap();
        std::fs::write(pi.join("done.md"),
            "---\nstatus: done\n---\nb").unwrap();
        std::env::set_var("HOME", &tmp);

        let out = render_inbox_list();
        assert!(out.starts_with("GLO 1"), "abbrev-less leads: {}", out);
        assert!(out.contains("BEE mi:2"), "abbrev channel: {}", out);
        assert!(!out.contains("pi:"), "empty omitted: {}", out);

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
