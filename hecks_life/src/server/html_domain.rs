//! HTML domain page — detail view for a single domain
//!
//! Shows modules (aggregates), commands, lifecycle states, and records
//! for one domain. Forms submit to the JSON dispatch endpoint.
//!
//! Usage:
//!   let page = generate_domain_page(&rt, &all_domains);

use crate::runtime::Runtime;
use std::cell::RefCell;
use std::collections::HashMap;
use super::html_shared::{wrap_page, sidebar_links, display_name, esc};

/// Generate the detail page for one domain
pub fn generate_domain_page(
    name: &str,
    rt: &RefCell<Runtime>,
    runtimes: &HashMap<String, RefCell<Runtime>>,
) -> String {
    let domains: Vec<(String, usize)> = {
        let mut d: Vec<_> = runtimes.iter()
            .map(|(n, r)| (n.clone(), r.borrow().domain.aggregates.len()))
            .collect();
        d.sort_by(|a, b| a.0.cmp(&b.0));
        d
    };
    let sidebar = sidebar_links(&domains, Some(name));
    let rt = rt.borrow();
    let mut main = String::new();
    main.push_str(&format!(
        r#"<div class="mb-1">
  <h1 class="text-3xl font-bold">{label}</h1>
</div>
<p class="text-gray-400 mb-8">{modules} modules, {policies} policies</p>"#,
        label = esc(&display_name(name)),
        modules = rt.domain.aggregates.len(),
        policies = rt.domain.policies.len(),
    ));

    for agg in &rt.domain.aggregates {
        main.push_str(&module_card(name, agg));
    }

    // Fixtures table
    if !rt.domain.fixtures.is_empty() {
        main.push_str(&fixtures_section(&rt.domain.fixtures));
    }

    wrap_page(&display_name(name), &sidebar, &main)
}

fn module_card(domain: &str, agg: &crate::ir::Aggregate) -> String {
    let mut s = format!(
        r#"<div class="bg-gray-800 rounded-lg border border-gray-700 p-6 mb-6" data-domain-aggregate="{agg_name}">
  <h2 class="text-xl font-semibold text-white mb-1">{label}</h2>
  <p class="text-sm text-gray-400 mb-4">{desc}</p>"#,
        agg_name = esc(&agg.name),
        label = esc(&display_name(&agg.name)),
        desc = esc(agg.description.as_deref().unwrap_or("")),
    );

    // Lifecycle badges
    if let Some(ref lc) = agg.lifecycle {
        s.push_str(r#"<div class="flex gap-2 mb-4">"#);
        let mut states: Vec<&str> = vec![&lc.default];
        for t in &lc.transitions {
            if !states.contains(&t.to_state.as_str()) {
                states.push(&t.to_state);
            }
        }
        for state in states {
            let color = if state == lc.default.as_str() {
                "bg-emerald-900 text-emerald-300"
            } else {
                "bg-gray-700 text-gray-300 hover:bg-gray-600 cursor-pointer"
            };
            s.push_str(&format!(
                r#"<span class="text-xs px-2 py-1 rounded {color}" onclick="filterByStatus(this, '{state}')">{state}</span>"#,
                color = color, state = esc(state),
            ));
        }
        s.push_str("</div>");
    }

    // Command buttons and forms
    s.push_str(r#"<div class="space-y-3">"#);
    for cmd in &agg.commands {
        s.push_str(&command_section(domain, cmd));
    }
    s.push_str("</div></div>");
    s
}

fn command_section(domain: &str, cmd: &crate::ir::Command) -> String {
    let mut fields = String::new();
    for attr in &cmd.attributes {
        fields.push_str(&format!(
            r#"<div>
  <label class="block text-xs text-gray-400 mb-1">{label}</label>
  <input name="{name}" type="text" placeholder="{atype}" class="w-full bg-gray-900 border border-gray-600 rounded px-3 py-2 text-sm text-gray-100 focus:border-blue-500 focus:outline-none">
</div>"#,
            label = esc(&display_name(&attr.name)),
            name = esc(&attr.name),
            atype = esc(&attr.attr_type),
        ));
    }
    let desc = cmd.description.as_deref().unwrap_or("");
    format!(
        r#"<details data-domain-command="{cmd_name}">
  <summary class="cursor-pointer px-4 py-2 bg-gray-700 hover:bg-gray-600 rounded-lg text-sm font-medium transition">{label}{role}</summary>
  <div class="mt-2 p-4 bg-gray-900 rounded-lg border border-gray-700">
    <p class="text-xs text-gray-500 mb-3">{desc}</p>
    <form method="POST" action="/domains/{domain}/dispatch" class="space-y-3"
          onsubmit="return submitCmd(this, '{cmd_name}')">
      {fields}
      <button type="submit" class="px-4 py-2 bg-blue-600 hover:bg-blue-500 rounded text-sm font-medium transition">Run</button>
      <span class="cmd-result text-xs text-gray-400 ml-3"></span>
    </form>
  </div>
</details>"#,
        cmd_name = esc(&cmd.name),
        label = esc(&display_name(&cmd.name)),
        role = cmd.role.as_ref()
            .map(|r| format!(r#" <span class="text-xs text-gray-500 ml-2">{}</span>"#, esc(r)))
            .unwrap_or_default(),
        desc = esc(desc),
        domain = domain,
        fields = fields,
    )
}

fn fixtures_section(fixtures: &[crate::ir::Fixture]) -> String {
    let mut s = String::from(
        r#"<div class="mt-8"><h2 class="text-xl font-semibold mb-4">Records</h2><div class="overflow-x-auto"><table class="w-full text-sm"><thead><tr class="border-b border-gray-700 text-left text-gray-400">"#,
    );
    // Only show Module column if there are mixed aggregate types
    let mixed = fixtures.windows(2).any(|w| w[0].aggregate_name != w[1].aggregate_name);
    let keys: Vec<String> = if let Some(f) = fixtures.first() {
        f.attributes.iter().map(|(k, _)| k.clone()).collect()
    } else { vec![] };
    if mixed {
        s.push_str("<th class=\"px-3 py-2\">Module</th>");
    }
    for k in &keys {
        s.push_str(&format!("<th class=\"px-3 py-2\">{}</th>", esc(&display_name(k))));
    }
    s.push_str("</tr></thead><tbody>");
    for fix in fixtures {
        s.push_str("<tr class=\"border-b border-gray-800\">");
        if mixed {
            s.push_str(&format!("<td class=\"px-3 py-2 text-gray-400\">{}</td>", esc(&fix.aggregate_name)));
        }
        for (_, v) in &fix.attributes {
            s.push_str(&format!("<td class=\"px-3 py-2\">{}</td>", esc(v)));
        }
        s.push_str("</tr>");
    }
    s.push_str("</tbody></table></div></div>");
    s
}
