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
    let total_policies: usize = runtimes.values()
        .map(|rt| rt.borrow().domain.policies.len()).sum();

    let mut main = String::new();
    main.push_str(&format!(
        r#"<h1 class="text-3xl font-bold mb-2 text-brand">Dashboard</h1>
<p class="text-gray-400 mb-8">All domains running on this server</p>
<div class="grid grid-cols-3 gap-6 mb-10">
  {}</div>
"#,
        metric_cards(domains.len(), total_modules, total_commands, total_policies),
    ));

    main.push_str(r#"<h2 class="text-xl font-semibold mb-4">Domains</h2><div class="grid grid-cols-1 md:grid-cols-2 gap-4">"#);
    for (name, _) in &domains {
        let rt = runtimes[name].borrow();
        let cat = rt.domain.category.as_deref().unwrap_or("general");
        let agg_count = rt.domain.aggregates.len();
        let cmd_count: usize = rt.domain.aggregates.iter()
            .map(|a| a.commands.len()).sum();
        main.push_str(&domain_card(name, cat, agg_count, cmd_count));
    }
    main.push_str("</div>");

    wrap_page("Dashboard", &sidebar, &main)
}

fn metric_cards(
    domains: usize, modules: usize, commands: usize, policies: usize,
) -> String {
    let card = |label: &str, value: usize, color: &str| -> String {
        format!(
            r#"<div class="bg-surface-2 rounded-lg border border-surface-3 p-6">
    <p class="text-sm text-gray-400">{label}</p>
    <p class="text-3xl font-bold {color} mt-1">{value}</p>
  </div>"#,
            label = label, value = value, color = color,
        )
    };
    format!(
        "{}{}{}{}",
        card("Domains", domains, "text-brand"),
        card("Modules", modules, "text-emerald-400"),
        card("Commands", commands, "text-amber-400"),
        card("Policies", policies, "text-purple-400"),
    )
}

fn domain_card(name: &str, category: &str, modules: usize, commands: usize) -> String {
    format!(
        r#"<a href="/domains/{name}" class="bg-surface-2 rounded-lg border border-surface-3 p-6 hover:border-gray-500 transition block">
  <div class="flex items-center justify-between mb-2">
    <h3 class="text-lg font-semibold text-white">{icon} {label}</h3>
    <span class="text-xs px-2 py-1 rounded bg-surface-3 text-gray-300">{category}</span>
  </div>
  <p class="text-sm text-gray-400">{modules} modules, {commands} commands</p>
</a>"#,
        name = name,
        icon = domain_icon(name),
        label = esc(&display_name(name)),
        category = esc(category),
        modules = modules,
        commands = commands,
    )
}
