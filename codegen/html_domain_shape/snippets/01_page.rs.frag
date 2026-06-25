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

    // Records table
    main.push_str(&records_table(&rt));

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

