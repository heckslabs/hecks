//! Per-module fixture tables — inline record display inside module cards
//!
//! Renders a compact table of fixtures filtered by aggregate name,
//! shown inside each module card on the Build tab.
//!
//! Usage:
//!   let html = module_fixtures(&fixtures, "Formula");

use crate::ir::Fixture;
use super::html_shared::{display_name, esc};

/// Render a fixture table for one aggregate, or helpful empty state
pub fn module_fixtures(fixtures: &[Fixture], aggregate_name: &str) -> String {
    let matched: Vec<&Fixture> = fixtures
        .iter()
        .filter(|f| f.aggregate_name == aggregate_name)
        .collect();
    if matched.is_empty() {
        return format!(
            r#"<div class="mt-4 p-4 rounded border border-dashed border-surface-4 text-center">
  <p class="text-sm text-gray-500">No records yet — use the commands above to create one</p>
</div>"#
        );
    }
    let keys: Vec<String> = matched[0]
        .attributes
        .iter()
        .map(|(k, _)| k.clone())
        .collect();
    let count = matched.len();
    let mut s = String::from(r#"<div class="mt-4">"#);
    s.push_str(&format!(
        r#"<p class="text-xs text-gray-500 mb-2">{} record{}</p>"#,
        count,
        if count == 1 { "" } else { "s" },
    ));
    s.push_str(r#"<div class="max-h-48 overflow-x-auto overflow-y-auto rounded border border-surface-3">"#);
    s.push_str(r#"<table class="min-w-full text-xs">"#);
    s.push_str(r#"<thead class="sticky top-0 bg-surface-2">"#);
    s.push_str(r#"<tr class="border-b border-surface-3 text-left text-gray-400">"#);
    for (i, k) in keys.iter().enumerate() {
        let sort_hint = if i == 0 { " \u{25B2}" } else { "" };
        s.push_str(&format!(
            r#"<th class="px-2 py-1 cursor-pointer hover:text-brand" onclick="sortTable(this)"{}>{}{}</th>"#,
            if i == 0 { " data-sort=\"asc\"" } else { "" },
            esc(&display_name(k)),
            sort_hint,
        ));
    }
    s.push_str("</tr></thead><tbody>");
    for fix in &matched {
        s.push_str(
            r#"<tr class="border-b border-surface-3 hover:bg-surface-3 cursor-pointer transition" onclick="showDetail(this)">"#,
        );
        for (_, v) in &fix.attributes {
            // Clean snake_case values for display
            let clean = if v.contains('_') && !v.contains('/') && !v.contains(' ') {
                display_name(v)
            } else {
                v.clone()
            };
            s.push_str(&format!(r#"<td class="px-2 py-1 whitespace-nowrap">{}</td>"#, esc(&clean)));
        }
        s.push_str("</tr>");
    }
    s.push_str("</tbody></table></div></div>");
    s
}

/// Render the full Records tab fixture table (all aggregates combined)
pub fn fixtures_section(fixtures: &[Fixture]) -> String {
    let count = fixtures.len();
    let mixed = fixtures.windows(2).any(|w| w[0].aggregate_name != w[1].aggregate_name);
    let keys: Vec<String> = fixtures.first().map(|f| {
        f.attributes.iter().map(|(k, _)| k.clone()).collect()
    }).unwrap_or_default();
    let th = "px-3 py-2 cursor-pointer hover:text-brand";
    let mut s = format!(
        r#"<div class="mt-8"><h2 class="text-xl font-semibold mb-4">Records</h2>
<p class="text-xs text-gray-500 mb-2">{count} record{pl}</p>
<div class="flex gap-3 mb-3"><input type="text" placeholder="Search records..." oninput="searchTable(this)" class="flex-1 bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none"></div>
<div class="max-h-96 overflow-x-auto overflow-y-auto rounded-lg border border-surface-3"><table class="w-full text-sm"><thead class="sticky top-0 bg-surface-2"><tr class="border-b border-surface-3 text-left text-gray-400">"#,
        pl = if count == 1 { "" } else { "s" },
    );
    let mut first = true;
    if mixed {
        s.push_str(&format!(
            "<th class=\"{th}\" onclick=\"sortTable(this)\" data-sort=\"asc\">Module \u{25B2}</th>"
        ));
        first = false;
    }
    for k in &keys {
        let (ds, arrow) = if first { (" data-sort=\"asc\"", " \u{25B2}") } else { ("", "") };
        s.push_str(&format!(
            "<th class=\"{th}\" onclick=\"sortTable(this)\"{ds}>{}{arrow}</th>",
            esc(&display_name(k))
        ));
        first = false;
    }
    s.push_str("</tr></thead><tbody>");
    for fix in fixtures {
        s.push_str(
            "<tr class=\"border-b border-surface-3 hover:bg-surface-3 cursor-pointer transition\" onclick=\"showDetail(this)\">"
        );
        if mixed {
            s.push_str(&format!(
                "<td class=\"px-3 py-2 text-gray-400\">{}</td>",
                esc(&fix.aggregate_name)
            ));
        }
        for (_, v) in &fix.attributes {
            s.push_str(&format!("<td class=\"px-3 py-2\">{}</td>", esc(v)));
        }
        s.push_str("</tr>");
    }
    s.push_str("</tbody></table></div></div>");
    s
}
