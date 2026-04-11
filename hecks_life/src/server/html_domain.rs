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
use super::html_shared::{wrap_page, sidebar_links, display_name, module_icon, esc};

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
        r#"<div class="mb-8">
  <h1 class="text-3xl font-bold text-brand">{label}</h1>
</div>
"#,
        label = esc(&display_name(name)),
    ));

    // Tabs: Build first, Records second
    main.push_str(r#"<div class="flex gap-4 mb-6 border-b border-surface-3">
  <button onclick="showTab('build')" id="tab-build" class="pb-2 px-1 text-sm font-medium border-b-2 border-brand text-brand">Build</button>
  <button onclick="showTab('records')" id="tab-records" class="pb-2 px-1 text-sm font-medium border-b-2 border-transparent text-gray-400 hover:text-white">Records</button>
</div>"#);

    // Build panel — shown by default
    main.push_str(r#"<div id="panel-build">"#);
    if rt.domain.aggregates.len() > 1 {
        main.push_str(&module_navbar(&rt.domain.aggregates));
    }
    for (idx, agg) in rt.domain.aggregates.iter().enumerate() {
        main.push_str(&module_card(name, agg, idx));
    }
    main.push_str("</div>");

    // Records panel — hidden by default
    main.push_str(r#"<div id="panel-records" class="hidden">"#);
    if !rt.domain.fixtures.is_empty() {
        main.push_str(&fixtures_section(&rt.domain.fixtures));
    }
    main.push_str("</div>");

    wrap_page(&display_name(name), &sidebar, &main)
}

fn module_navbar(aggregates: &[crate::ir::Aggregate]) -> String {
    let mut s = String::from("<nav class=\"flex flex-wrap gap-2 mb-6\">");
    for agg in aggregates {
        s.push_str(&format!(
            "<a href=\"#{}\" onclick=\"var d=document.getElementById('{}');if(d)d.open=true\" class=\"px-3 py-1 text-xs rounded-full bg-surface-2 border border-surface-3 text-gray-400 hover:text-brand hover:border-brand\">{}</a>",
            esc(&agg.name), esc(&agg.name), esc(&display_name(&agg.name)),
        ));
    }
    s.push_str("</nav>");
    s
}

fn module_card(domain: &str, agg: &crate::ir::Aggregate, index: usize) -> String {
    let open_attr = if index == 0 { " open" } else { "" };
    let icon = module_icon(&agg.name);
    let mut s = format!(
        r#"<details id="{agg_name}" class="bg-surface-2 rounded-lg border border-surface-3 mb-6" data-domain-aggregate="{agg_name}"{open_attr}>
  <summary class="p-6 cursor-pointer flex items-center justify-between">
    <div>
      <h2 class="text-xl font-bold">{icon} {label}</h2>
      <p class="text-gray-400 text-sm mt-1">{desc}</p>
    </div>
    <span class="text-gray-500">▾</span>
  </summary>
  <div class="px-6 pb-6">"#,
        agg_name = esc(&agg.name),
        open_attr = open_attr,
        icon = icon,
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
                "bg-surface-3 text-gray-300 hover:bg-gray-600 cursor-pointer"
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
    s.push_str("</div></div></details>");
    s
}

fn command_section(domain: &str, cmd: &crate::ir::Command) -> String {
    let mut fields = String::new();
    for attr in &cmd.attributes {
        fields.push_str(&format!(
            r#"<div>
  <label class="block text-xs text-gray-400 mb-1">{label}</label>
  <input name="{name}" type="text" placeholder="{atype}" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none">
</div>"#,
            label = esc(&display_name(&attr.name)),
            name = esc(&attr.name),
            atype = esc(&attr.attr_type),
        ));
    }
    let desc = cmd.description.as_deref().unwrap_or("");
    format!(
        r#"<details data-domain-command="{cmd_name}">
  <summary class="cursor-pointer px-4 py-2 bg-surface-3 hover:bg-surface-4 rounded-lg text-sm font-medium transition list-none [&::-webkit-details-marker]:hidden">{label}{role}</summary>
  <div class="mt-2 p-4 bg-surface-1 rounded-lg border border-surface-3">
    <p class="text-xs text-gray-500 mb-3">{desc}</p>
    <form method="POST" action="/domains/{domain}/dispatch" class="grid grid-cols-2 gap-3"
          onsubmit="return submitCmd(this, '{cmd_name}')">
      {fields}
      <div class="col-span-2 flex items-center gap-3">
        <button type="submit" class="px-4 py-1.5 bg-surface-3 hover:bg-surface-4 border border-surface-4 rounded text-sm font-medium transition text-brand">Execute</button>
        <span class="cmd-result text-xs text-gray-400"></span>
      </div>
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
        r#"<div class="mt-8"><h2 class="text-xl font-semibold mb-4">Records</h2>"#,
    );
    s.push_str(r#"<div class="flex gap-3 mb-3"><input type="text" placeholder="Search records..." oninput="searchTable(this)" class="flex-1 bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none"></div>"#);
    s.push_str(r#"<div class="max-h-96 overflow-y-auto rounded-lg border border-surface-3"><table class="w-full text-sm"><thead class="sticky top-0 bg-surface-2"><tr class="border-b border-surface-3 text-left text-gray-400">"#);
    // Only show Module column if there are mixed aggregate types
    let mixed = fixtures.windows(2).any(|w| w[0].aggregate_name != w[1].aggregate_name);
    let keys: Vec<String> = if let Some(f) = fixtures.first() {
        f.attributes.iter().map(|(k, _)| k.clone()).collect()
    } else { vec![] };
    let th_class = "px-3 py-2 cursor-pointer hover:text-brand";
    if mixed {
        s.push_str(&format!("<th class=\"{}\" onclick=\"sortTable(this)\">Module</th>", th_class));
    }
    for k in &keys {
        s.push_str(&format!("<th class=\"{}\" onclick=\"sortTable(this)\">{}</th>", th_class, esc(&display_name(k))));
    }
    s.push_str("</tr></thead><tbody>");
    for fix in fixtures {
        s.push_str("<tr class=\"border-b border-surface-3 hover:bg-surface-3 cursor-pointer transition\" onclick=\"showDetail(this)\">");
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
