//! HTML domain page — detail view for a single domain
//!
//! Shows modules (aggregates), commands, lifecycle states, and records
//! for one domain. Forms submit to the JSON dispatch endpoint.
//!
//! i534 walking-skeleton upgrades :
//!   - i106 typed inputs + i107 reference pickers + i109 required marks
//!     are delegated to `html_form::render_command_form`.
//!   - i108 every command per aggregate renders as a collapsible
//!     `<details>` card (creator open by default).
//!   - i112 per-aggregate icons read from `html_icons::module_icon`'s
//!     bin-buddy fallback table.
//!   - i113 rules (lifecycle invariants) render inside the aggregate
//!     card, scoped to that aggregate's commands.
//!
//! Usage:
//!   let page = generate_domain_page(&rt, &all_domains);

use crate::runtime::Runtime;
use std::cell::RefCell;
use std::collections::HashMap;
use super::html_shared::{wrap_page_with_domain, display_name, module_icon, esc};
use super::html_sidebar::sidebar_tree;
use super::html_fixtures::fixtures_section;
use super::html_usage::usage_section;
use super::html_form::render_command_form;
use super::html_rules::collect_invariants_for;

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
    let rt = rt.borrow();
    let sidebar = sidebar_tree(&domains, name, &rt.domain);
    let mut main = String::new();
    main.push_str(&format!(
        r#"<div class="mb-8 flex items-baseline justify-between">
  <h1 class="text-3xl font-bold text-brand">{label}</h1>
  <a href="/diagram/{name}" class="text-sm px-3 py-1.5 rounded-lg bg-surface-2 border border-surface-3 text-gray-300 hover:bg-brand hover:text-black hover:border-brand transition">📊 View as Living Diagram →</a>
</div>
"#,
        name = name,
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

    // Divider — use aggregate names as the label, not "Records"
    let agg_names: Vec<String> = rt.domain.aggregates.iter()
        .map(|a| display_name(&a.name))
        .collect();
    let divider_label = if agg_names.is_empty() {
        "Records".to_string()
    } else {
        agg_names.join(", ")
    };
    main.push_str(&format!(
        r#"<div class="flex items-center gap-3 mb-6"><hr class="flex-1 border-surface-3"><span class="text-xs text-gray-500 uppercase tracking-wider">{}</span><hr class="flex-1 border-surface-3"></div>"#,
        esc(&divider_label),
    ));

    // Records table — wrapped in a stable id so wizardSubmit can
    // re-fetch the page and swap this section live after a dispatch
    // (the panel must show the store, and the store just changed).
    main.push_str(r#"<div id="records-section">"#);
    main.push_str(&records_table(&rt));
    main.push_str("</div>");

    wrap_page_with_domain(&display_name(name), Some(name), &sidebar, &main)
}

/// Creation cards — one per aggregate, with every command rendered as a
/// collapsible details panel (i108) and lifecycle rules scoped to the
/// aggregate (i113).
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
        let icon = module_icon(&agg.name);
        let desc = agg.description.as_deref().unwrap_or("");

        // i549 — collect the distinct roles this aggregate exposes via
        // its commands. The top-bar role filter (rendered in
        // html_shared::top_bar's accompanying JS) toggles
        // `aria-hidden` + `display:none` on cards whose data-roles
        // doesn't include the selected role. "All" shows everything.
        let mut roles: Vec<String> = agg
            .commands
            .iter()
            .filter_map(|c| c.role.as_ref().map(|r| r.to_ascii_lowercase()))
            .collect();
        roles.sort();
        roles.dedup();
        let roles_attr = roles.join(",");

        s.push_str(&format!(
            r#"<div id="agg-{anchor}" data-aggregate="{anchor}" data-roles="{roles_attr}" class="bg-surface-2 rounded-xl border border-surface-3 p-5 hover:border-brand/30 transition scroll-mt-24">
  <div class="mb-3">
    <h3 class="font-semibold text-white">{icon} {label}</h3>
    <p class="text-xs text-gray-500 mt-1">{desc}</p>
  </div>"#,
            anchor = esc(&agg.name),
            roles_attr = esc(&roles_attr),
            icon = icon,
            label = esc(&display_name(&agg.name)),
            desc = esc(desc),
        ));

        s.push_str(&render_agg_commands(domain, agg, rt));
        s.push_str(&render_agg_rules(agg));

        s.push_str("</div>");
    }

    s.push_str("</div>");
    s
}

/// Render every command on an aggregate as a stacked <details> panel
/// (i108). The first command (the create / entry point) is open by
/// default ; downstream action commands stay collapsed until the
/// operator clicks. Each form delegates type-aware input rendering and
/// reference pickers to `html_form::render_command_form`.
fn render_agg_commands(domain: &str, agg: &crate::ir::Aggregate, rt: &Runtime) -> String {
    if agg.commands.is_empty() { return String::new(); }
    let mut s = String::new();
    s.push_str(r#"<div class="space-y-2">"#);

    // Order : create command (no references) first, then action
    // commands. Within each group, declaration order is preserved.
    let mut ordered: Vec<&crate::ir::Command> = Vec::with_capacity(agg.commands.len());
    for c in &agg.commands {
        if c.references.is_empty() { ordered.push(c); }
    }
    for c in &agg.commands {
        if !c.references.is_empty() { ordered.push(c); }
    }

    for (i, cmd) in ordered.iter().enumerate() {
        let open = if i == 0 { " open" } else { "" };
        let goal = cmd.description.as_deref().unwrap_or("");
        let role = cmd.role.as_deref().unwrap_or("");
        let role_html = if role.is_empty() {
            String::new()
        } else {
            format!(
                r#" <span class="text-xs text-gray-500">as {}</span>"#,
                esc(role),
            )
        };
        let goal_html = if goal.is_empty() {
            String::new()
        } else {
            format!(
                r#"<p class="text-xs text-gray-500 mb-2">{}</p>"#,
                esc(goal),
            )
        };
        s.push_str(&format!(
            r#"<details{open} data-domain-command="{cmd_name}" class="bg-surface-1 rounded-lg border border-surface-3">
  <summary class="cursor-pointer px-3 py-2 text-sm font-medium text-white hover:bg-surface-3 rounded-t-lg flex items-center justify-between">
    <span><span class="text-brand">▸</span> {label}{role}</span>
  </summary>
  <div class="px-3 pb-3 pt-1">
    {goal_html}
    {form}
  </div>
</details>"#,
            open = open,
            cmd_name = esc(&cmd.name),
            label = esc(&display_name(&cmd.name)),
            role = role_html,
            goal_html = goal_html,
            form = render_command_form(domain, agg, cmd, rt),
        ));
    }

    s.push_str("</div>");
    s
}

/// i113 — render the lifecycle rules / invariants gathered from every
/// `given` declaration on the aggregate's commands. Empty givens collapse
/// to no section. Same display shape as the previous global dump, just
/// scoped to one aggregate's commands so the rule sits beside the form
/// that enforces it.
fn render_agg_rules(agg: &crate::ir::Aggregate) -> String {
    let invariants = collect_invariants_for(agg);
    if invariants.is_empty() { return String::new(); }
    let mut s = String::new();
    s.push_str(r#"<div class="mt-4 pt-3 border-t border-surface-3">"#);
    s.push_str(r#"<p class="text-xs text-gray-500 uppercase tracking-wider mb-2">Rules</p>"#);
    s.push_str(r#"<ul class="space-y-1">"#);
    for (cmd_name, rule) in &invariants {
        s.push_str(&format!(
            r#"<li class="text-sm text-gray-300"><span class="text-white">{}</span> requires {}</li>"#,
            esc(&display_name(cmd_name)), esc(rule),
        ));
    }
    s.push_str("</ul></div>");
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

/// Records table — LIVE event-sourced records first (the store is the
/// truth ; a refresh must show what was dispatched, not just declared
/// fixtures). Falls back to the bluebook's declared fixtures for
/// fixture-only demos, then to the empty-state hint.
fn records_table(rt: &Runtime) -> String {
    let live = live_records_section(rt);
    if !live.is_empty() {
        return live;
    }
    if !rt.domain.fixtures.is_empty() {
        return fixtures_section(&rt.domain.fixtures);
    }
    r#"<div class="p-8 rounded-lg border border-dashed border-surface-4 text-center">
  <p class="text-gray-500">No records yet — use the palette above to dispatch a command</p>
</div>"#.to_string()
}

/// Render every aggregate's live repository records as per-aggregate
/// tables. Columns follow the aggregate's declared attribute order (the
/// IR is the contract) ; an ID column leads. Returns "" when no
/// aggregate holds any record, so the caller can fall back.
fn live_records_section(rt: &Runtime) -> String {
    let mut body = String::new();
    let mut total = 0usize;
    for agg in &rt.domain.aggregates {
        let items = rt.all(&agg.name);
        if items.is_empty() {
            continue;
        }
        total += items.len();
        // Columns : references first (tool, member, …), then declared
        // attributes — both in IR order. A reference is part of the
        // record's shape ; omitting it hid the very field that links
        // aggregates together.
        let keys: Vec<&str> = agg
            .references
            .iter()
            .map(|r| r.name.as_str())
            .chain(agg.attributes.iter().map(|a| a.name.as_str()))
            .collect();
        body.push_str(&format!(
            r#"<h3 class="font-semibold text-brand mt-6 mb-2">{} <span class="text-xs text-gray-500 font-normal">{} record{}</span></h3>"#,
            esc(&display_name(&agg.name)),
            items.len(),
            if items.len() == 1 { "" } else { "s" },
        ));
        body.push_str(r#"<div class="max-h-96 overflow-x-auto overflow-y-auto rounded-lg border border-surface-3"><table class="w-full text-sm"><thead class="sticky top-0 bg-surface-2"><tr class="border-b border-surface-3 text-left text-gray-400">"#);
        body.push_str(r#"<th class="px-3 py-2">ID</th>"#);
        for k in &keys {
            body.push_str(&format!(r#"<th class="px-3 py-2">{}</th>"#, esc(&display_name(k))));
        }
        body.push_str("</tr></thead><tbody>");
        for item in &items {
            body.push_str(r#"<tr class="border-b border-surface-3 hover:bg-surface-3 transition">"#);
            body.push_str(&format!(r#"<td class="px-3 py-2 text-gray-400">{}</td>"#, esc(&item.id)));
            for k in &keys {
                let cell = item.fields.get(*k).map(display_value).unwrap_or_default();
                body.push_str(&format!(r#"<td class="px-3 py-2">{}</td>"#, esc(&cell)));
            }
            body.push_str("</tr>");
        }
        body.push_str("</tbody></table></div>");
    }
    if total == 0 {
        return String::new();
    }
    format!(
        r#"<div class="mt-8"><h2 class="text-xl font-semibold mb-4">Records</h2>{}</div>"#,
        body
    )
}

/// Human-readable cell for a runtime Value — strings bare (no quotes),
/// scalars via Display, lists/maps compact JSON.
fn display_value(v: &crate::runtime::Value) -> String {
    use crate::runtime::Value;
    match v {
        Value::Str(s) => s.clone(),
        Value::Null => String::new(),
        Value::List(items) if items.is_empty() => String::new(),
        other => crate::json_helpers::value_to_json(other),
    }
}

