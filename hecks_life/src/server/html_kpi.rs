//! KPI cards — summary indicators at the top of each domain page
//!
//! Shows module count, record count, command count, and per-lifecycle-state
//! counts derived from the domain's fixtures.
//!
//! Usage:
//!   let html = kpi_cards(&rt);

use crate::runtime::Runtime;
use super::html_shared::{display_name, esc};

/// Render the KPI card strip for one domain
pub fn kpi_cards(rt: &Runtime) -> String {
    let modules = rt.domain.aggregates.len();
    let records = rt.domain.fixtures.len();
    let commands: usize = rt.domain.aggregates.iter()
        .map(|a| a.commands.len())
        .sum();
    let mut s = String::from(
        "<div class=\"grid grid-cols-2 md:grid-cols-4 gap-3 mb-6\">"
    );
    s.push_str(&card("Modules", modules, "text-brand"));
    s.push_str(&card("Records", records, "text-emerald-400"));
    s.push_str(&card("Commands", commands, "text-amber-400"));

    // Lifecycle state counts from fixture data
    let mut state_counts: Vec<(String, usize)> = Vec::new();
    for agg in &rt.domain.aggregates {
        if let Some(ref lc) = agg.lifecycle {
            let field = &lc.field;
            for fix in &rt.domain.fixtures {
                if fix.aggregate_name == agg.name {
                    if let Some(val) = fix.attributes.iter()
                        .find(|(k, _)| k == field)
                        .map(|(_, v)| v.clone())
                    {
                        if let Some(entry) = state_counts.iter_mut()
                            .find(|(s, _)| *s == val)
                        {
                            entry.1 += 1;
                        } else {
                            state_counts.push((val, 1));
                        }
                    }
                }
            }
        }
    }
    for (state, count) in &state_counts {
        s.push_str(&card(&display_name(state), *count, "text-purple-400"));
    }

    s.push_str("</div>");
    s
}

fn card(label: &str, value: usize, color: &str) -> String {
    format!(
        r#"<div class="bg-surface-2 rounded-lg border border-surface-3 p-4">
  <p class="text-xs text-gray-400">{label}</p>
  <p class="text-2xl font-bold {color}">{value}</p>
</div>"#,
        label = esc(label),
        color = color,
        value = value,
    )
}
