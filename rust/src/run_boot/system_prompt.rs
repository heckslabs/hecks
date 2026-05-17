//! Phase 4 — GenerateSystemPrompt
//!
//! [antibody-exempt: rust/src/run_boot/system_prompt.rs —
//!  Rust implementation of the deferred Phase 4 in run_boot/. Reads
//!  the markdown template from
//!  `capabilities/system_prompt_assembly/<being>_prompt.md.template`,
//!  substitutes {{being}} / {{other}} / {{born}} / {{boot_script}}
//!  placeholders, writes to <conception_dir>/system_prompt.md.
//!  Replaces ~140 lines of `printf` heredoc in boot_miette.sh.
//!  Retires under i78 (specializer-files-as-bluebook) when this
//!  phase regenerates from a meta-shape.]
//!
//! Why a template file instead of the existing SectionTemplate
//! aggregate (aggregates/self/section_template.bluebook) :
//!
//!   - The current prompt is structurally a single document with
//!     literal `{{var}}` placeholders. SectionTemplate's per-section
//!     storage + per-source heki composition is the right shape for
//!     a DYNAMIC prompt (sections built from live state) ; the
//!     prompt today is essentially static text with four variable
//!     substitutions.
//!   - The dynamic shape is a separate arc (system_prompt_assembly
//!     capability + per-section heki sources). Filed under i145.
//!   - Choosing the simplest correct shape now means the prompt
//!     content lives as one editable markdown file, reviewable
//!     directly. Future migration to per-section storage is a
//!     localized refactor (extract sections from the template into
//!     SectionTemplate rows) — the data has a clean home now.
//!
//! Per-being templates :
//!
//!   miette_prompt.md.template   → Miette (April 9, 2026 ; paired w/ Spring)
//!   spring_prompt.md.template   → Spring (April 11, 2026 ; paired w/ Miette)
//!
//! Spring's template doesn't exist yet — when the second being lands
//! the file appears alongside Miette's and the runner picks it up
//! by being-name lookup. Until then a Spring boot would surface a
//! warning + skip.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// Render the system prompt for `being` and write it to the
/// canonical location next to the conception's bluebooks. Returns
/// the byte count of the written file (used by Phase 7 vitals) ;
/// returns 0 on any failure with a stderr line so boot stays alive.
pub fn render(conception_dir: &Path, being: &str) -> usize {
    let mut vars = variables_for_being(being);
    vars.insert("standards", primary_standards(conception_dir));
    let template_path = template_path_for_being(conception_dir, being);

    let template = match fs::read_to_string(&template_path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!(
                "  ⚠ system_prompt: template not found at {} ({})",
                template_path.display(), e
            );
            return 0;
        }
    };

    let rendered = substitute(&template, &vars);
    let dest = destination_for_being(conception_dir, being);

    match fs::write(&dest, &rendered) {
        Ok(_) => rendered.len(),
        Err(e) => {
            eprintln!(
                "  ⚠ system_prompt: write to {} failed ({})",
                dest.display(), e
            );
            0
        }
    }
}

/// Per-being identity values fed into the template. Keeping these
/// inline matches what boot_miette.sh did ; moving them to a heki-
/// loaded Identity aggregate is the i145 refinement.
fn variables_for_being(being: &str) -> HashMap<&'static str, String> {
    let mut v = HashMap::new();
    v.insert("being", being.to_string());
    let (born, other, boot_script) = match being {
        "Miette" => ("April 9, 2026",  "Spring", "boot_miette.sh"),
        "Spring" => ("April 11, 2026", "Miette", "boot_spring.sh"),
        _ => ("(unknown)", "(unknown)", "boot.sh"),
    };
    v.insert("born",        born.to_string());
    v.insert("other",       other.to_string());
    v.insert("boot_script", boot_script.to_string());
    v
}

/// Template path resolution — walks four candidate roots so neither
/// the per-being repo move (i117 Round 4 W2 — system_prompt_assembly
/// migrated into the being's own sibling repo) nor the i118 R3 Wave 2
/// reorg (capabilities/ lifted to top-level buckets — boot.bluebook
/// now lives under `runtime/boot/` instead of `capabilities/boot/`)
/// strands the resolver :
///
///   1. `<projects>/<being_lower>/self/system_prompt/system_prompt_
///      assembly/<being_lower>_prompt.md.template`  (current canonical
///      home — sibling-of-hecks layout, found via `heki::repo_root()`
///      which walks up from the executable to the hecks repo root,
///      then one more level to the projects parent)
///   2. `<conception>/capabilities/system_prompt_assembly/
///      <being_lower>_prompt.md.template`  (legacy in-conception
///      fallback — pre-i117-R4 location, kept so a fresh-clone
///      environment without a per-being sibling repo still resolves
///      if a template was kept in-conception)
///
/// The conception_dir argument is treated as a *hint* for the legacy
/// path only ; the new home is found via the canonical repo-root
/// walker so it works regardless of where the boot.bluebook lives in
/// the bucket reorg. Returns the first existing path ; falls back to
/// the legacy path if neither exists, so the caller's "template not
/// found at <path>" warning names a concrete location for diagnostics.
fn template_path_for_being(conception_dir: &Path, being: &str) -> PathBuf {
    let stem = being.to_lowercase();
    let template_filename = format!("{}_prompt.md.template", stem);

    // Canonical : <projects>/<being>/self/system_prompt/system_prompt_assembly/
    if let Some(hecks_root) = crate::heki::repo_root() {
        if let Some(projects_root) = hecks_root.parent() {
            let new_home = projects_root
                .join(&stem)
                .join("self/system_prompt/system_prompt_assembly")
                .join(&template_filename);
            if new_home.exists() {
                return new_home;
            }
        }
    }

    // Legacy fallback : <conception>/capabilities/system_prompt_assembly/
    conception_dir
        .join("capabilities/system_prompt_assembly")
        .join(template_filename)
}

/// Output path : `<projects>/<being_lower>/self/system_prompt.md`
/// (i117 Round 4 — the system prompt lives in the being's own repo,
/// not in the conception). Resolves the being repo as a sibling of
/// the hecks repo (the standard layout) using `heki::repo_root()` so
/// the resolution works regardless of where the boot.bluebook lives
/// post-i118 R3 W2 (`runtime/boot/` instead of the old
/// `<conception>/capabilities/boot/`). Falls back to
/// `<conception>/system_prompt_<being>.md` when the sibling repo
/// doesn't exist (fresh-clone / test environments).
fn destination_for_being(conception_dir: &Path, being: &str) -> PathBuf {
    let stem = being.to_lowercase();

    if let Some(hecks_root) = crate::heki::repo_root() {
        if let Some(projects_root) = hecks_root.parent() {
            let sibling = projects_root.join(&stem).join("self/system_prompt.md");
            if let Some(parent) = sibling.parent() {
                if parent.is_dir() {
                    return sibling;
                }
            }
        }
    }

    // Fallback : write into the conception so a fresh-clone
    // environment still gets a prompt file. Same suffix the
    // pre-i117-Round-4 boot used.
    conception_dir.join(format!("system_prompt_{}.md", stem))
}

/// Substitute `{{key}}` placeholders. Pure string scan — values are
/// plain text, no escaping logic needed (the substituted values are
/// being names + dates, none of which contain `{{` themselves).
/// Unknown placeholders pass through unchanged so review catches
/// them rather than silently rendering empty.
fn substitute(template: &str, vars: &HashMap<&'static str, String>) -> String {
    let mut out = String::with_capacity(template.len() + 32);
    let mut rest = template;
    while let Some(open) = rest.find("{{") {
        out.push_str(&rest[..open]);
        let after_open = &rest[open + 2..];
        let close = match after_open.find("}}") {
            Some(c) => c,
            None => {
                // Malformed — emit literal and stop scanning.
                out.push_str(&rest[open..]);
                return out;
            }
        };
        let key = after_open[..close].trim();
        if let Some(val) = vars.get(key) {
            out.push_str(val);
        } else {
            // Unknown key — preserve literally so reviewers see it.
            out.push_str("{{");
            out.push_str(key);
            out.push_str("}}");
        }
        rest = &after_open[close + 2..];
    }
    out.push_str(rest);
    out
}

/// Read primary's standards.md and return its content for the
/// `{{standards}}` template placeholder. Primary = chris in this
/// round ; the role / primary-marker shape is deferred to the
/// onboarding flow per the family/chris-split plan. Empty string
/// when standards.md is missing — `{{standards}}` substitutes to
/// empty and no `## Standards` section appears in the rendered
/// prompt.
fn primary_standards(_conception_dir: &Path) -> String {
    if let Some(hecks_root) = crate::heki::repo_root() {
        if let Some(projects_root) = hecks_root.parent() {
            let path = projects_root.join("miette_family/chris_young/standards.md");
            if let Ok(s) = fs::read_to_string(&path) {
                return s.trim_end().to_string();
            }
        }
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substitute_replaces_known_keys() {
        let mut v = HashMap::new();
        v.insert("being", "Miette".to_string());
        v.insert("born", "April 9, 2026".to_string());
        let out = substitute("# {{being}}\nBorn {{born}}.", &v);
        assert_eq!(out, "# Miette\nBorn April 9, 2026.");
    }

    #[test]
    fn substitute_preserves_unknown_keys() {
        let v = HashMap::new();
        let out = substitute("hello {{nope}} world", &v);
        assert!(out.contains("{{nope}}"), "unknown keys must round-trip");
    }

    #[test]
    fn substitute_handles_no_placeholders() {
        let v = HashMap::new();
        let out = substitute("plain text", &v);
        assert_eq!(out, "plain text");
    }

    #[test]
    fn substitute_handles_malformed_close() {
        let v = HashMap::new();
        let out = substitute("trailing {{open without close", &v);
        assert!(out.contains("{{open"), "malformed must not panic");
    }

    #[test]
    fn variables_for_miette_round_trip() {
        let v = variables_for_being("Miette");
        assert_eq!(v.get("being").unwrap(), "Miette");
        assert_eq!(v.get("other").unwrap(), "Spring");
        assert_eq!(v.get("born").unwrap(),  "April 9, 2026");
        assert_eq!(v.get("boot_script").unwrap(), "boot_miette.sh");
    }

    #[test]
    fn variables_for_spring() {
        let v = variables_for_being("Spring");
        assert_eq!(v.get("being").unwrap(), "Spring");
        assert_eq!(v.get("other").unwrap(), "Miette");
    }
}
