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

