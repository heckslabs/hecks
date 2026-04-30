//! Phase 4 — GenerateSystemPrompt
//!
//! [antibody-exempt: hecks_life/src/run_boot/system_prompt.rs —
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
    let vars = variables_for_being(being);
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

/// Template path : `<conception>/capabilities/system_prompt_assembly/
/// <being_lower>_prompt.md.template`.
fn template_path_for_being(conception_dir: &Path, being: &str) -> PathBuf {
    let stem = being.to_lowercase();
    conception_dir
        .join("capabilities/system_prompt_assembly")
        .join(format!("{}_prompt.md.template", stem))
}

/// Output path : `~/Projects/<being_lower>/self/system_prompt.md`
/// (i117 Round 4 — the system prompt lives in the being's own repo,
/// not in the conception). Resolves the being repo as a sibling of
/// the hecks repo (the standard layout). Falls back to
/// `<conception>/system_prompt_<being>.md` when the sibling doesn't
/// exist (development/test environments without the per-being repo).
fn destination_for_being(conception_dir: &Path, being: &str) -> PathBuf {
    let stem = being.to_lowercase();
    if let Some(repo_root) = conception_dir.parent().and_then(|p| p.parent()) {
        let sibling = repo_root.join(&stem).join("self/system_prompt.md");
        if let Some(parent) = sibling.parent() {
            if parent.is_dir() {
                return sibling;
            }
        }
    }
    // Fallback : write into the conception so a fresh-clone
    // environment still gets a prompt file. Same suffix the
    // pre-i117-Round-4 boot used.
    if being == "Miette" {
        conception_dir.join(format!("system_prompt_{}.md", stem))
    } else {
        conception_dir.join(format!("system_prompt_{}.md", stem))
    }
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
