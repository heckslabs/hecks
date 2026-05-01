//! Report renderer — walks a bluebook-declared section list and prints
//! a tabular dashboard. The bluebook (capabilities/status/status.bluebook)
//! declares each section as `section "Title" do row "label", :field … end`;
//! the renderer reads each row's value off the assembled Report by
//! field name. Adding a new section is one bluebook edit, not a Rust touch.
//!
//! When the bluebook declares zero sections, the renderer falls back to a
//! built-in default layout so old bluebooks (and the parity tests that
//! exercise them) keep printing what they always did. Authors migrating
//! a capability to declared sections delete nothing on the Rust side —
//! they just add `section "X" do … end` blocks and the new layout takes
//! over.
//!
//! Color: bold-cyan headers, bold-yellow labels when `on` is true ;
//! plaintext when the caller has NO_COLOR or --no-color.
//!
//! List-shaped extensions (open_themes / unfiled wishes top / daemons
//! liveness rows / recent commits) are NOT yet declarable as bluebook
//! rows — they're appended after the matching declared section by
//! title-match. Filed as gap : `section_lists_in_bluebook` (i105
//! follow-up). Until then the renderer hard-codes the auxiliary lines
//! attached to "Awareness" / "Dream wishes" / "Daemons" / "Recent
//! commits".
//!
//! File concerns are split for the size budget :
//!   * field_lookup.rs — bluebook field name → Report value mapping,
//!     plus per-field composer helpers (fatigue_with_state, etc.).
//!   * default_layout.rs — legacy hard-coded layout used when the
//!     bluebook declares no sections.
//! This file holds the orchestrator and the small drawing primitives
//! shared by both.

use super::assemble::Report;
use super::default_layout;
use super::field_lookup::lookup_field;
use crate::ir::Section;

pub const SECTION_WIDTH: usize = 60;
pub const LABEL_WIDTH: usize = 18;

pub fn render_with_sections(r: &Report, on: bool, sections: &[Section]) -> Vec<String> {
    if sections.is_empty() {
        return default_layout::render_all(r, on);
    }
    let mut out = Vec::new();
    for section in sections {
        push_declared_section(r, section, on, &mut out);
        // Title-match list extensions for sections that include lists in
        // their built-in form. Tracked as gap section_lists_in_bluebook.
        match section.title.as_str() {
            "Awareness" => default_layout::append_awareness_lists(r, on, &mut out),
            "Dream wishes" => default_layout::append_wishes_top(r, on, &mut out),
            _ => {}
        }
    }
    out
}

fn push_declared_section(r: &Report, section: &Section, on: bool, out: &mut Vec<String>) {
    // Daemons + Recent commits are pure-list sections — declared rows
    // (if any) print first, then the built-in list block. Until
    // section_lists_in_bluebook lands, this is how we keep the dashboard
    // tabular without forcing every section to be either-or.
    if section.title == "Daemons" {
        for row in &section.rows {
            push_row(out, &row.label, &lookup_field(r, &row.field), on);
        }
        default_layout::daemons(r, on, out);
        return;
    }
    if section.title == "Recent commits" {
        default_layout::recent_commits(r, on, out);
        return;
    }
    push_section_header(out, &section.title, on);
    for row in &section.rows {
        push_row(out, &row.label, &lookup_field(r, &row.field), on);
    }
}

fn push_row(out: &mut Vec<String>, label: &str, value: &str, on: bool) {
    let label_padded = format!("{}:", label);
    let lbl = paint(&format!("{:width$}", label_padded, width = LABEL_WIDTH), "1;33", on);
    out.push(format!("  {} {}", lbl, value));
}

fn push_section_header(out: &mut Vec<String>, title: &str, on: bool) {
    let dashes = SECTION_WIDTH.saturating_sub(title.chars().count() + 4);
    out.push(paint(&format!("─── {} {}", title, "─".repeat(dashes)), "1;36", on));
}

pub fn push_section(lines: &mut Vec<String>, title: &str, rows: &[(&str, &str)], on: bool) {
    let dashes = SECTION_WIDTH.saturating_sub(title.chars().count() + 4);
    lines.push(paint(&format!("─── {} {}", title, "─".repeat(dashes)), "1;36", on));
    for (label, value) in rows {
        let label_padded = format!("{}:", label);
        let lbl = paint(&format!("{:width$}", label_padded, width = LABEL_WIDTH), "1;33", on);
        lines.push(format!("  {} {}", lbl, value));
    }
}

pub fn paint(text: &str, code: &str, on: bool) -> String {
    if on { format!("\x1b[{}m{}\x1b[0m", code, text) } else { text.to_string() }
}

pub fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max { s.to_string() }
    else { format!("{}…", s.chars().take(max - 1).collect::<String>()) }
}
