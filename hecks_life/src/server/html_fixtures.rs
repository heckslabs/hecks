//! Per-module fixture tables — inline record display inside module cards
//!
//! Renders a compact table of fixtures filtered by aggregate name,
//! shown inside each module card on the Build tab.
//!
//! Usage:
//!   let html = module_fixtures(&fixtures, "Formula");

use crate::ir::Fixture;
use super::html_shared::{display_name, esc};

/// Render a fixture table for one aggregate, or empty string if none
pub fn module_fixtures(fixtures: &[Fixture], aggregate_name: &str) -> String {
    let matched: Vec<&Fixture> = fixtures
        .iter()
        .filter(|f| f.aggregate_name == aggregate_name)
        .collect();
    if matched.is_empty() {
        return String::new();
    }
    let keys: Vec<String> = matched[0]
        .attributes
        .iter()
        .map(|(k, _)| k.clone())
        .collect();
    let mut s = String::from(r#"<div class="mt-4">"#);
    s.push_str(&format!(
        r#"<h3 class="text-sm font-medium text-gray-400 mb-2">Records ({})</h3>"#,
        matched.len(),
    ));
    s.push_str(r#"<div class="max-h-48 overflow-y-auto rounded border border-surface-3">"#);
    s.push_str(r#"<table class="w-full text-xs">"#);
    s.push_str(r#"<thead class="sticky top-0 bg-surface-2">"#);
    s.push_str(r#"<tr class="border-b border-surface-3 text-left text-gray-400">"#);
    for k in &keys {
        s.push_str(&format!(
            r#"<th class="px-2 py-1">{}</th>"#,
            esc(&display_name(k)),
        ));
    }
    s.push_str("</tr></thead><tbody>");
    for fix in &matched {
        s.push_str(
            r#"<tr class="border-b border-surface-3 hover:bg-surface-3 transition">"#,
        );
        for (_, v) in &fix.attributes {
            s.push_str(&format!(r#"<td class="px-2 py-1">{}</td>"#, esc(v)));
        }
        s.push_str("</tr>");
    }
    s.push_str("</tbody></table></div></div>");
    s
}
