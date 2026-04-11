//! Sidebar navigation — grouped domain links and utility helpers
//!
//! Generates the sidebar HTML with domains grouped under category
//! headers (Operations, Products, Sales, Compliance).
//!
//! Usage:
//!   let links = sidebar_links(&domains, Some("manufacturing"));

/// Generate sidebar nav links from domain names, highlighting active
pub fn sidebar_links(domains: &[(String, usize)], active: Option<&str>) -> String {
    let groups: &[(&str, &[&str])] = &[
        ("Operations", &["manufacturing", "inventory", "supply_chain", "distribution", "quality"]),
        ("Products", &["catalog", "formulation", "formulation_lab", "pricing"]),
        ("Sales", &["brand_strategy", "customer_personas", "storefront"]),
        ("Compliance", &["compliance", "regulatory_compliance", "claims", "demand"]),
    ];
    let mut out = String::new();
    let mut placed = std::collections::HashSet::new();
    for (header, members) in groups {
        let group_domains: Vec<_> = members.iter()
            .filter_map(|m| domains.iter().find(|(n, _)| n == m))
            .collect();
        if group_domains.is_empty() { continue; }
        out.push_str(&format!(
            r#"<div class="mt-4 mb-1 px-3 text-xs font-bold uppercase tracking-wider text-gray-600">{}</div>"#,
            header
        ));
        for (name, _count) in &group_domains {
            placed.insert(name.clone());
            out.push_str(&sidebar_link(name, active));
        }
    }
    // Ungrouped domains
    let ungrouped: Vec<_> = domains.iter().filter(|(n, _)| !placed.contains(n)).collect();
    if !ungrouped.is_empty() && !placed.is_empty() {
        out.push_str(r#"<div class="mt-4 mb-1 px-3 text-xs font-bold uppercase tracking-wider text-gray-600">Other</div>"#);
    }
    for (name, _) in ungrouped {
        out.push_str(&sidebar_link(name, active));
    }
    out
}

fn sidebar_link(name: &str, active: Option<&str>) -> String {
    let active_class = if active == Some(name) {
        "bg-brand/15 text-brand border-l-2 border-brand font-semibold"
    } else {
        "text-gray-400 hover:bg-surface-2 hover:text-white"
    };
    let icon = super::html_shared::domain_icon(name);
    let label = super::html_shared::display_name(name);
    format!(
        r#"<a href="/domains/{name}" data-domain-aggregate="{name}" title="Open {label}" class="block px-3 py-1.5 rounded-lg text-sm {active_class} transition cursor-pointer">
  {icon} {label}
</a>"#,
    )
}
