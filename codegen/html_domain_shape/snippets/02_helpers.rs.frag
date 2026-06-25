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

