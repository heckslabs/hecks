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
use super::html_fixtures::{module_fixtures, fixtures_section};
use super::html_kpi::kpi_cards;
use super::html_usage::usage_section;

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

    // Vision
    if let Some(ref vision) = rt.domain.vision {
        main.push_str(&format!(
            r#"<p class="text-gray-400 mb-6">{}</p>"#, esc(vision),
        ));
    }

    // Usage — how to use this domain, inferred from the bluebook
    main.push_str(&usage_section(&rt.domain));

    // Creation cards — one per aggregate, compact, always visible
    main.push_str(&creation_cards(name, &rt));

    // Divider
    main.push_str(r#"<div class="flex items-center gap-3 mb-6"><hr class="flex-1 border-surface-3"><span class="text-xs text-gray-500 uppercase tracking-wider">Records</span><hr class="flex-1 border-surface-3"></div>"#);

    // Records table
    main.push_str(&records_table(&rt));

    wrap_page(&display_name(name), &sidebar, &main)
}

/// Creation cards — one per aggregate, compact form for the create command
fn creation_cards(domain: &str, rt: &Runtime) -> String {
    let mut s = String::new();
    let agg_count = rt.domain.aggregates.len();
    let cols = match agg_count {
        1 => "grid-cols-1",
        2 => "grid-cols-1 md:grid-cols-2",
        _ => "grid-cols-1 md:grid-cols-2 lg:grid-cols-3",
    };
    s.push_str(&format!(r#"<div class="grid {} gap-4 mb-8">"#, cols));

    for agg in &rt.domain.aggregates {
        // Find the create command (no reference_to)
        let create_cmd = agg.commands.iter().find(|c| c.references.is_empty());
        let icon = module_icon(&agg.name);
        let desc = agg.description.as_deref().unwrap_or("");

        s.push_str(&format!(
            r#"<div class="bg-surface-2 rounded-xl border border-surface-3 p-5 hover:border-brand/30 transition">
  <div class="mb-3">
    <h3 class="font-semibold text-white">{icon} {label}</h3>
    <p class="text-xs text-gray-500 mt-1">{desc}</p>
  </div>"#,
            icon = icon,
            label = esc(&display_name(&agg.name)),
            desc = esc(desc),
        ));

        if let Some(cmd) = create_cmd {
            let goal = cmd.description.as_deref().unwrap_or("");
            let field_count = cmd.attributes.len();
            let form_cols = if field_count <= 3 { "grid-cols-1" } else { "grid-cols-2" };
            s.push_str(&format!(
                r#"<form onsubmit="return wizardSubmit(this, '{domain}', '{cmd_name}')" class="space-y-2">
  <div class="grid {form_cols} gap-2">"#,
                form_cols = form_cols,
                domain = esc(domain),
                cmd_name = esc(&cmd.name),
            ));

            for attr in &cmd.attributes {
                let input_type = match attr.attr_type.to_lowercase().as_str() {
                    "float" | "integer" | "int" => "number",
                    _ => "text",
                };
                let step = if attr.attr_type.to_lowercase() == "float" { r#" step="any""# } else { "" };
                let placeholder = esc(&display_name(&attr.name));
                s.push_str(&format!(
                    r#"<input name="{name}" type="{input_type}"{step} placeholder="{placeholder}" class="bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none w-full">"#,
                    name = esc(&attr.name),
                    input_type = input_type,
                    step = step,
                    placeholder = placeholder,
                ));
            }

            s.push_str("</div>");
            let btn_label = display_name(&cmd.name);
            s.push_str(&format!(
                r#"<button type="submit" class="w-full px-4 py-2 bg-brand/10 border border-brand/30 rounded-lg text-brand text-sm font-medium hover:bg-brand/20 transition">{label}</button>
  <div class="wizard-result"></div>
</form>"#,
                label = esc(&btn_label),
            ));
        } else {
            s.push_str(r#"<p class="text-xs text-gray-600 italic">No create command</p>"#);
        }

        s.push_str("</div>");
    }

    s.push_str("</div>");
    s
}

/// The Glass command palette — one input, fuzzy match, inline form (kept for future use)
#[allow(dead_code)]
fn command_palette(domain: &str, rt: &Runtime) -> String {
    // Build JSON index of all commands for JS to search
    let mut cmds_json = Vec::new();
    for agg in &rt.domain.aggregates {
        for cmd in &agg.commands {
            let is_create = cmd.references.is_empty();
            let fields: Vec<String> = cmd.attributes.iter().map(|a| {
                format!(r#"{{"name":"{}","type":"{}"}}"#, esc(&a.name), esc(&a.attr_type))
            }).collect();
            let goal = cmd.description.as_deref().unwrap_or("");
            let role = cmd.role.as_deref().unwrap_or("");
            let event = cmd.emits.as_deref().unwrap_or("");
            cmds_json.push(format!(
                r#"{{"name":"{}","aggregate":"{}","goal":"{}","role":"{}","event":"{}","create":{},"fields":[{}]}}"#,
                esc(&cmd.name), esc(&agg.name), esc(goal), esc(role), esc(event),
                is_create, fields.join(","),
            ));
        }
    }

    format!(
        r#"<div class="mb-8">
  <div class="relative">
    <input id="glass-input" type="text" placeholder="Type a command... (e.g. create battery, add circuit)"
      class="w-full bg-surface-2 border border-surface-3 rounded-xl px-5 py-4 text-lg text-gray-100 focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand/30 transition"
      oninput="glassPalette(this.value)"
      onkeydown="glassPaletteKey(event)"
      autocomplete="off">
    <span class="absolute right-4 top-4 text-gray-500 text-sm">⚡ Glass</span>
  </div>
  <div id="glass-dropdown" class="mt-1 bg-surface-2 border border-surface-3 rounded-xl overflow-hidden hidden shadow-xl"></div>
  <div id="glass-form" class="mt-4 hidden"></div>
</div>
<script>
const GLASS_CMDS = [{cmds}];
const GLASS_DOMAIN = '{domain}';
let glassIdx = -1;
let glassMatches = [];

function glassPalette(q) {{
  const dd = document.getElementById('glass-dropdown');
  if (!q || q.length < 1) {{ dd.classList.add('hidden'); glassMatches = []; glassIdx = -1; return; }}
  const ql = q.toLowerCase();
  glassMatches = GLASS_CMDS.filter(c =>
    humanize(c.name).toLowerCase().includes(ql) ||
    c.aggregate.toLowerCase().includes(ql) ||
    c.goal.toLowerCase().includes(ql)
  ).slice(0, 8);
  if (glassMatches.length === 0) {{ dd.classList.add('hidden'); return; }}
  glassIdx = 0;
  renderGlassDropdown();
  dd.classList.remove('hidden');
}}

function renderGlassDropdown() {{
  const dd = document.getElementById('glass-dropdown');
  dd.innerHTML = glassMatches.map((c, i) => {{
    const sel = i === glassIdx ? 'bg-brand/10 border-l-2 border-brand' : 'border-l-2 border-transparent';
    const tag = c.create ? '<span class="text-xs bg-emerald-900/40 text-emerald-400 px-1.5 py-0.5 rounded">create</span>' : '<span class="text-xs bg-surface-3 text-gray-400 px-1.5 py-0.5 rounded">action</span>';
    return '<div class="px-4 py-3 cursor-pointer hover:bg-surface-3 transition ' + sel + '" onclick="glassSelect(' + i + ')">' +
      '<div class="flex items-center gap-2">' +
        '<span class="font-semibold text-white">' + humanize(c.name) + '</span>' +
        tag +
        (c.role ? '<span class="text-xs text-gray-500">' + c.role + '</span>' : '') +
      '</div>' +
      '<p class="text-xs text-gray-400 mt-0.5">' + c.goal + '</p>' +
      '<p class="text-xs text-gray-600">' + humanize(c.aggregate) + (c.event ? ' → ' + humanize(c.event) : '') + '</p>' +
    '</div>';
  }}).join('');
}}

function glassPaletteKey(e) {{
  if (glassMatches.length === 0) return;
  if (e.key === 'ArrowDown') {{ e.preventDefault(); glassIdx = (glassIdx + 1) % glassMatches.length; renderGlassDropdown(); }}
  else if (e.key === 'ArrowUp') {{ e.preventDefault(); glassIdx = glassIdx > 0 ? glassIdx - 1 : glassMatches.length - 1; renderGlassDropdown(); }}
  else if (e.key === 'Enter' && glassIdx >= 0) {{ e.preventDefault(); glassSelect(glassIdx); }}
  else if (e.key === 'Escape') {{ document.getElementById('glass-dropdown').classList.add('hidden'); glassMatches = []; glassIdx = -1; }}
}}

function glassSelect(i) {{
  const c = glassMatches[i];
  document.getElementById('glass-dropdown').classList.add('hidden');
  document.getElementById('glass-input').value = humanize(c.name);
  glassMatches = [];
  glassIdx = -1;
  // Build inline form
  const form = document.getElementById('glass-form');
  const cols = c.fields.length >= 4 ? 'grid-cols-2 md:grid-cols-3' : 'grid-cols-1 md:grid-cols-2';
  let fields = '<div class="grid ' + cols + ' gap-3">';
  c.fields.forEach(f => {{
    fields += '<div><label class="block text-xs text-gray-400 mb-1">' + humanize(f.name) + '</label>' + fieldInput(f) + '</div>';
  }});
  fields += '</div>';
  form.innerHTML = '<div class="bg-surface-2 rounded-xl border border-surface-3 p-5">' +
    '<div class="flex items-center justify-between mb-3">' +
      '<h3 class="font-semibold text-brand">' + humanize(c.name) + '</h3>' +
      '<button onclick="document.getElementById(\'glass-form\').classList.add(\'hidden\');document.getElementById(\'glass-input\').value=\'\'" class="text-xs text-gray-500 hover:text-white">✕</button>' +
    '</div>' +
    (c.goal ? '<p class="text-xs text-gray-400 mb-4">' + c.goal + '</p>' : '') +
    '<form onsubmit="return wizardSubmit(this, \'' + GLASS_DOMAIN + '\', \'' + c.name + '\')">' +
      fields +
      '<div class="flex items-center gap-3 mt-4">' +
        '<button type="submit" class="px-5 py-2 bg-brand text-surface-0 font-medium rounded-lg hover:bg-brand-dim transition">' + humanize(c.name) + '</button>' +
        (c.event ? '<span class="text-xs text-gray-500">emits ' + humanize(c.event) + '</span>' : '') +
      '</div>' +
      '<div class="wizard-result mt-3"></div>' +
    '</form>' +
  '</div>';
  form.classList.remove('hidden');
  form.style.opacity = '0';
  form.style.transform = 'translateY(-8px)';
  requestAnimationFrame(() => {{
    form.style.transition = 'opacity 0.25s ease, transform 0.25s ease';
    form.style.opacity = '1';
    form.style.transform = 'translateY(0)';
  }});
  form.querySelector('input,select')?.focus();
}}
</script>"#,
        cmds = cmds_json.join(","),
        domain = esc(domain),
    )
}

/// Records table — all fixtures/records for this domain
fn records_table(rt: &Runtime) -> String {
    if rt.domain.fixtures.is_empty() {
        return r#"<div class="p-8 rounded-lg border border-dashed border-surface-4 text-center">
  <p class="text-gray-500">No records yet — use the palette above to dispatch a command</p>
</div>"#.to_string();
    }
    fixtures_section(&rt.domain.fixtures)
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

    // Command buttons and forms — create commands first, then actions
    let creates: Vec<_> = agg.commands.iter().filter(|c| c.references.is_empty()).collect();
    let actions: Vec<_> = agg.commands.iter().filter(|c| !c.references.is_empty()).collect();

    s.push_str(r#"<div class="space-y-3">"#);
    for cmd in &creates {
        s.push_str(&command_section(domain, cmd));
    }
    if !creates.is_empty() && !actions.is_empty() {
        s.push_str(r#"<div class="flex items-center gap-3 my-4"><hr class="flex-1 border-surface-3"><span class="text-xs text-gray-500 uppercase tracking-wider">on existing</span><hr class="flex-1 border-surface-3"></div>"#);
    }
    for cmd in &actions {
        s.push_str(&command_section(domain, cmd));
    }
    s.push_str("</div>");

    // Per-module fixture table
    s.push_str(&module_fixtures(fixtures, &agg.name));

    s.push_str("</div></details>");
    s
}

fn command_section(domain: &str, cmd: &crate::ir::Command) -> String {
    let is_create = cmd.references.is_empty();
    if is_create {
        return wizard_button(domain, cmd);
    }
    inline_form(domain, cmd)
}

fn wizard_button(domain: &str, cmd: &crate::ir::Command) -> String {
    let fields_json: Vec<String> = cmd.attributes.iter().map(|a| {
        format!(r#"{{"name":"{}","type":"{}"}}"#, esc(&a.name), esc(&a.attr_type))
    }).collect();
    let label = display_name(&cmd.name);
    format!(
        r#"<button onclick='openWizard("{domain}", "{cmd_name}", [{fields}])' class="w-full px-4 py-3 bg-brand/10 border border-brand/30 rounded-lg text-brand font-medium hover:bg-brand/20 transition text-left">+ {label}</button>"#,
        domain = esc(domain),
        cmd_name = esc(&cmd.name),
        fields = fields_json.join(","),
        label = esc(&label),
    )
}

fn inline_form(domain: &str, cmd: &crate::ir::Command) -> String {
    let mut fields = String::new();
    for attr in &cmd.attributes {
        let input_type = match attr.attr_type.to_lowercase().as_str() {
            "float" | "integer" | "int" => "number",
            _ => "text",
        };
        let step = if attr.attr_type.to_lowercase() == "float" { r#" step="any""# } else { "" };
        let placeholder = match attr.attr_type.to_lowercase().as_str() {
            "float" => "0.0",
            "integer" | "int" => "0",
            _ => &attr.attr_type,
        };
        fields.push_str(&format!(
            r#"<div>
  <label class="block text-xs text-gray-400 mb-1">{label} <span class="text-brand">*</span></label>
  <input name="{name}" type="{input_type}"{step} placeholder="{placeholder}" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none">
</div>"#,
            label = esc(&display_name(&attr.name)),
            name = esc(&attr.name),
            input_type = input_type,
            step = step,
            placeholder = placeholder,
        ));
    }
    let desc = cmd.description.as_deref().unwrap_or("");
    let btn_label = esc(&display_name(&cmd.name));
    format!(
        r#"<details data-domain-command="{cmd_name}">
  <summary class="cursor-pointer px-4 py-2 bg-surface-3 hover:bg-surface-4 rounded-lg text-sm font-medium transition list-none [&::-webkit-details-marker]:hidden">{label}{role} <button onclick="event.stopPropagation();showHelp(this)" class="ml-1 text-xs text-gray-500 hover:text-brand opacity-30 hover:opacity-100 transition">?</button></summary>
  <div class="mt-2 p-4 bg-surface-1 rounded-lg border border-surface-3">
    <p class="text-xs text-gray-500 mb-3">{desc}</p>
    <form method="POST" action="/domains/{domain}/dispatch" class="grid grid-cols-2 md:grid-cols-3 gap-3"
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

