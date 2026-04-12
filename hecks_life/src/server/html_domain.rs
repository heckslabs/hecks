//! HTML domain page — detail view for a single domain
//!
//! Shows modules (aggregates), commands, lifecycle states, and records
//! for one domain. Forms submit to the JSON dispatch endpoint.
//!
//! Usage:
//!   let page = generate_domain_page(&rt, &all_domains);

use crate::runtime::Runtime;
use crate::ir::Fixture;
use std::cell::RefCell;
use std::collections::HashMap;
use super::html_shared::{wrap_page, sidebar_links, display_name, module_icon, esc};
use super::html_workflow::workflow_pipeline;
use super::html_fixtures::module_fixtures;
use super::html_kpi::kpi_cards;

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

    // KPI cards
    main.push_str(&kpi_cards(&rt));

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
        main.push_str(&module_card(name, agg, idx, &rt.domain.fixtures));
    }
    main.push_str("</div>");

    // Records panel — hidden by default
    main.push_str(r#"<div id="panel-records" class="hidden">"#);
    if rt.domain.fixtures.is_empty() {
        main.push_str(r#"<div class="mt-8 p-8 rounded-lg border border-dashed border-surface-4 text-center">
  <p class="text-gray-500">No records yet — use the Build tab to create one</p>
</div>"#);
    } else {
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

fn module_card(
    domain: &str, agg: &crate::ir::Aggregate, index: usize, fixtures: &[Fixture],
) -> String {
    let open_attr = if index == 0 { " open" } else { "" };
    let icon = module_icon(&agg.name);
    let mut s = format!(
        r#"<details id="{agg_name}" class="bg-surface-2 rounded-lg border border-surface-3 mb-6" data-domain-aggregate="{agg_name}"{open_attr}>
  <summary class="p-6 cursor-pointer flex items-center justify-between">
    <div>
      <h2 class="text-xl font-bold">{icon} {label} <button onclick="event.stopPropagation();showHelp(this)" class="ml-2 text-xs text-gray-500 hover:text-brand opacity-30 hover:opacity-100 transition">?</button></h2>
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

    // Workflow pipeline (replaces lifecycle badges)
    if let Some(ref lc) = agg.lifecycle {
        s.push_str(&workflow_pipeline(lc, &agg.commands));
    }

    // Command buttons and forms
    s.push_str(r#"<div class="space-y-3">"#);
    for cmd in &agg.commands {
        s.push_str(&command_section(domain, cmd));
    }
    s.push_str("</div>");

    // Per-module fixture table
    s.push_str(&module_fixtures(fixtures, &agg.name));

    s.push_str("</div></details>");
    s
}

fn command_section(domain: &str, cmd: &crate::ir::Command) -> String {
    let mut fields = String::new();
    for attr in &cmd.attributes {
        fields.push_str(&format!(
            r#"<div>
  <label class="block text-xs text-gray-400 mb-1">{label} <span class="text-brand">*</span></label>
  <input name="{name}" type="text" placeholder="{atype}" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none">
</div>"#,
            label = esc(&display_name(&attr.name)),
            name = esc(&attr.name),
            atype = esc(&attr.attr_type),
        ));
    }
    let desc = cmd.description.as_deref().unwrap_or("");
    let btn_label = esc(&display_name(&cmd.name));
    format!(
        r#"<details data-domain-command="{cmd_name}">
  <summary class="cursor-pointer px-4 py-2 bg-surface-3 hover:bg-surface-4 rounded-lg text-sm font-medium transition list-none [&::-webkit-details-marker]:hidden">{label}{role} <button onclick="event.stopPropagation();showHelp(this)" class="ml-1 text-xs text-gray-500 hover:text-brand opacity-30 hover:opacity-100 transition">?</button></summary>
  <div class="mt-2 p-4 bg-surface-1 rounded-lg border border-surface-3">
    <p class="text-xs text-gray-500 mb-3">{desc}</p>
    <form method="POST" action="/domains/{domain}/dispatch" class="grid grid-cols-2 gap-3"
          onsubmit="return submitCmd(this, '{cmd_name}')">
      {fields}
      <div class="col-span-2">
        <button type="submit" class="px-5 py-2 bg-brand/20 hover:bg-brand/30 border border-brand rounded text-sm font-medium transition text-brand cursor-pointer">{btn_label}</button>
        <div class="cmd-result mt-2 text-sm py-2 px-4 rounded hidden"></div>
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
        btn_label = btn_label,
    )
}

fn fixtures_section(fixtures: &[crate::ir::Fixture]) -> String {
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
        s.push_str(&format!("<th class=\"{th}\" onclick=\"sortTable(this)\" data-sort=\"asc\">Module \u{25B2}</th>"));
        first = false;
    }
    for k in &keys {
        let (ds, arrow) = if first { (" data-sort=\"asc\"", " \u{25B2}") } else { ("", "") };
        s.push_str(&format!("<th class=\"{th}\" onclick=\"sortTable(this)\"{ds}>{}{arrow}</th>", esc(&display_name(k))));
        first = false;
    }
    s.push_str("</tr></thead><tbody>");
    for fix in fixtures {
        s.push_str("<tr class=\"border-b border-surface-3 hover:bg-surface-3 cursor-pointer transition\" onclick=\"showDetail(this)\">");
        if mixed { s.push_str(&format!("<td class=\"px-3 py-2 text-gray-400\">{}</td>", esc(&fix.aggregate_name))); }
        for (_, v) in &fix.attributes { s.push_str(&format!("<td class=\"px-3 py-2\">{}</td>", esc(v))); }
        s.push_str("</tr>");
    }
    s.push_str("</tbody></table></div></div>");
    s
}
