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

    wrap_page(&display_name(name), &sidebar, &main)
}

/// Creation cards — one per aggregate, forms for all commands
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

        s.push_str(&format!(
            r#"<div id="agg-{anchor}" class="bg-surface-2 rounded-xl border border-surface-3 p-5 hover:border-brand/30 transition scroll-mt-24">
  <div class="mb-3">
    <h3 class="font-semibold text-white">{icon} {label}</h3>
    <p class="text-xs text-gray-500 mt-1">{desc}</p>
  </div>"#,
            anchor = esc(&agg.name),
            icon = icon,
            label = esc(&display_name(&agg.name)),
            desc = esc(desc),
        ));

        s.push_str(&aggregate_form(domain, agg));

        s.push_str("</div>");
    }

    s.push_str("</div>");
    s
}

/// One unified form per aggregate — entity fields + value object fields together.
fn aggregate_form(domain: &str, agg: &crate::ir::Aggregate) -> String {
    // Find the create command (entry point)
    let create_cmd = agg.commands.iter().find(|c| c.references.is_empty());
    let create_cmd = match create_cmd {
        Some(c) => c,
        None => return String::new(),
    };

    // Collect all value object field names to identify VO sections
    let vo_field_names: Vec<Vec<&str>> = agg.value_objects.iter()
        .map(|vo| vo.attributes.iter().map(|a| a.name.as_str()).collect())
        .collect();

    // Find the action command whose attrs overlap a value object (e.g. AddEntry)
    let child_cmd = agg.commands.iter().find(|c| {
        !c.references.is_empty() && vo_field_names.iter().any(|vo_names| {
            c.attributes.iter().filter(|a| vo_names.contains(&a.name.as_str())).count() >= 3
        })
    });

    let mut s = String::new();

    // The form dispatches the create command; JS will chain the child if present
    let cmd_name = if child_cmd.is_some() && create_cmd.attributes.len() <= 1 {
        // If create is trivial (just a name), dispatch the child command instead
        // and include the create fields inline
        child_cmd.unwrap().name.as_str()
    } else {
        create_cmd.name.as_str()
    };

    s.push_str(&format!(
        r#"<form onsubmit="return wizardSubmit(this, '{domain}', '{cmd_name}')" class="space-y-2 mb-3">"#,
        domain = esc(domain),
        cmd_name = esc(cmd_name),
    ));

    // Entity-level fields from create command
    let create_cols = if create_cmd.attributes.len() <= 3 { "grid-cols-1" } else { "grid-cols-2" };
    if !create_cmd.attributes.is_empty() {
        s.push_str(&format!(r#"<div class="grid {} gap-2">"#, create_cols));
        for attr in &create_cmd.attributes {
            s.push_str(&field_input(attr));
        }
        s.push_str("</div>");
    }

    // Value object section — fields from the child command grouped under VO label
    if let Some(child) = child_cmd {
        let matched_vo = agg.value_objects.iter().find(|vo| {
            let names: Vec<&str> = vo.attributes.iter().map(|a| a.name.as_str()).collect();
            child.attributes.iter().filter(|a| names.contains(&a.name.as_str())).count() >= 3
        });
        let label = matched_vo
            .and_then(|vo| vo.description.as_deref())
            .unwrap_or_else(|| matched_vo.map(|vo| vo.name.as_str()).unwrap_or("Details"));
        let cols = if child.attributes.len() <= 3 { "grid-cols-1" } else { "grid-cols-2" };
        s.push_str(&format!(
            r#"<div class="mt-2 pt-2 border-t border-surface-3">
  <p class="text-xs text-gray-400 mb-2">{}</p>
  <div class="grid {} gap-2">"#,
            esc(label), cols,
        ));
        for attr in &child.attributes {
            s.push_str(&field_input(attr));
        }
        s.push_str("</div></div>");
    }

    let btn_label = display_name(&create_cmd.name);
    s.push_str(&format!(
        r#"<button type="submit" class="w-full px-4 py-2 bg-brand/10 border border-brand/30 rounded-lg text-brand text-sm font-medium hover:bg-brand/20 transition mt-2">{label}</button>
  <div class="wizard-result"></div>
</form>"#,
        label = esc(&btn_label),
    ));
    s
}

