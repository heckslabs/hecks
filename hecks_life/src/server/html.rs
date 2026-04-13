//! HTML index page — dashboard listing all domains
//!
//! Generates the main landing page with domain metrics
//! and navigation. Uses Tailwind CDN for styling.
//!
//! Usage:
//!   let page = generate_index(&runtimes);

use crate::runtime::Runtime;
use std::cell::RefCell;
use std::collections::HashMap;
use super::html_shared::{wrap_page, sidebar_links, display_name, domain_icon, esc};

/// Generate the full index page listing all domains
pub fn generate_index(runtimes: &HashMap<String, RefCell<Runtime>>) -> String {
    let mut domains: Vec<(String, usize)> = runtimes
        .iter()
        .map(|(name, rt)| (name.clone(), rt.borrow().domain.aggregates.len()))
        .collect();
    domains.sort_by(|a, b| a.0.cmp(&b.0));

    let sidebar = sidebar_links(&domains, None);
    let total_modules: usize = domains.iter().map(|(_, c)| c).sum();
    let total_commands: usize = runtimes.values().map(|rt| {
        rt.borrow().domain.aggregates.iter()
            .map(|a| a.commands.len()).sum::<usize>()
    }).sum();
    let total_fixtures: usize = runtimes.values()
        .map(|rt| rt.borrow().domain.fixtures.len()).sum();

    let mut main = String::new();
    main.push_str(&format!(
        r#"<h1 class="text-3xl font-bold mb-2 text-brand">Dashboard</h1>
<p class="text-gray-400 mb-8">How is your business doing today?</p>
<div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4 mb-10">
  {}</div>
"#,
        metric_cards(domains.len(), total_modules, total_commands, total_fixtures),
    ));

    main.push_str(r#"<h2 class="text-xl font-semibold mb-4">Modules</h2><div class="grid grid-cols-1 md:grid-cols-2 gap-4">"#);
    for (name, _) in &domains {
        let rt = runtimes[name].borrow();
        let cat = rt.domain.category.as_deref().unwrap_or("general");
        let desc = rt.domain.aggregates.first()
            .and_then(|a| a.description.as_deref())
            .unwrap_or("");
        main.push_str(&domain_card(name, cat, desc));
    }
    main.push_str("</div>");

    wrap_page("Dashboard", &sidebar, &main)
}

fn metric_cards(
    domains: usize, modules: usize, commands: usize, records: usize,
) -> String {
    let card = |label: &str, value: &str, color: &str, hint: &str| -> String {
        format!(
            r#"<div class="bg-surface-2 rounded-lg border border-surface-3 p-6">
    <p class="text-sm text-gray-400">{label}</p>
    <p class="text-3xl font-bold {color} mt-1">{value}</p>
    <p class="text-xs text-gray-500 mt-2">{hint}</p>
  </div>"#,
        )
    };
    format!(
        "{}{}{}{}",
        card("Domains", &domains.to_string(), "text-brand", "Bounded contexts"),
        card("Modules", &modules.to_string(), "text-emerald-400", "Across all domains"),
        card("Actions", &commands.to_string(), "text-amber-400", "Available commands"),
        card("Records", &records.to_string(), "text-purple-400", "Seeded data"),
    )
}

fn domain_card(name: &str, _category: &str, description: &str) -> String {
    let desc = if description.is_empty() {
        format!("Manage your {}", display_name(name).to_lowercase())
    } else {
        description.to_string()
    };
    format!(
        r#"<a href="/domains/{name}" class="bg-surface-2 rounded-lg border border-surface-3 p-6 hover:border-brand/50 hover:shadow-lg hover:shadow-brand/5 transition cursor-pointer block">
  <div class="mb-2">
    <h3 class="text-lg font-semibold text-white">{icon} {label}</h3>
  </div>
  <p class="text-sm text-gray-400">{desc}</p>
</a>"#,
        name = name,
        icon = domain_icon(name),
        label = esc(&display_name(name)),
        desc = esc(&desc),
    )
}
