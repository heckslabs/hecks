//! Shared HTML layout — app shell, head, sidebar, footer
//!
//! Provides the Tailwind-styled page wrapper used by both
//! the index page and individual domain pages.
//!
//! Usage:
//!   let page = wrap_page("Title", &sidebar, &content);

/// Wrap content in the full app shell with sidebar
pub fn wrap_page(title: &str, sidebar_html: &str, main_html: &str) -> String {
    let app_name = "IGB";
    let app_subtitle = "Engine Additive Platform";
    let help_script = super::html_help::help_script();
    format!(
        r#"<!DOCTYPE html>
<html lang="en" class="h-full">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title} — {app_name}</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Roboto+Slab:wght@700&family=Cabin:wght@400;700&display=swap" rel="stylesheet">
  <style>
    body {{ font-family: 'Cabin', sans-serif; }}
    h1, h2, h3 {{ font-family: 'Roboto Slab', serif; }}
  </style>
  <script>
  tailwind.config = {{
    theme: {{
      extend: {{
        colors: {{
          brand: {{ DEFAULT: '#ffe400', dim: '#ffd200', glow: 'rgba(255,228,0,0.15)' }},
          surface: {{ 0: '#111111', 1: '#1a1a1a', 2: '#222222', 3: '#333e48', 4: '#444444' }}
        }}
      }}
    }}
  }}
  </script>
  <style>
    html {{ scroll-behavior: smooth; }}
    details > summary {{ list-style: none; }}
    details > summary::-webkit-details-marker {{ display: none; }}
    details[open] > div {{ animation: slideDown 0.2s ease-out; }}
    @keyframes slideDown {{ from {{ opacity: 0; transform: translateY(-8px); }} to {{ opacity: 1; transform: translateY(0); }} }}
    @keyframes blob-drift-1 {{ 0% {{ transform: translate(0,0) scale(1); }} 50% {{ transform: translate(-5vw,8vh) scale(0.9); }} 100% {{ transform: translate(0,0) scale(1); }} }}
    @keyframes blob-drift-2 {{ 0% {{ transform: translate(0,0) scale(1); }} 50% {{ transform: translate(7vw,-10vh) scale(0.88); }} 100% {{ transform: translate(0,0) scale(1); }} }}
    .page-blob {{
      position: fixed; border-radius: 50%; filter: blur(100px);
      opacity: 0.06; pointer-events: none; will-change: transform;
    }}
  </style>
  <script>
  function submitCmd(form, cmd) {{
    const data = {{}};
    new FormData(form).forEach((v, k) => {{ if(v) data[k] = v; }});
    fetch(form.action, {{
      method: 'POST',
      headers: {{'Content-Type': 'application/json'}},
      body: JSON.stringify({{command: cmd, attrs: data}})
    }}).then(r => r.json()).then(r => {{
      const el = form.querySelector('.cmd-result');
      el.classList.remove('hidden', 'bg-emerald-900/40', 'text-emerald-300', 'bg-red-900/40', 'text-red-300');
      if (r.ok) {{
        el.textContent = '\u2714 Done — ' + (r.event || 'success');
        el.classList.add('bg-emerald-900/40', 'text-emerald-300');
        form.querySelectorAll('input').forEach(i => i.value = '');
        addEvent(r.event, cmd, r.aggregate_type, r.aggregate_id, true);
      }} else {{
        el.textContent = '\u2718 Error: ' + r.error;
        el.classList.add('bg-red-900/40', 'text-red-300');
        addEvent(r.error, cmd, '', '', false);
      }}
    }});
    return false;
  }}
  function humanize(s) {{ return s.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/_/g, ' '); }}
  function addEvent(event, cmd, aggType, aggId, ok) {{
    const stream = document.getElementById('event-stream');
    if (!stream) return;
    const hint = stream.querySelector('p.italic');
    if (hint) hint.remove();
    const time = new Date().toLocaleTimeString();
    const color = ok ? 'border-emerald-600/40' : 'border-red-600/40';
    const icon = ok ? '\u26A1' : '\u274C';
    const card = document.createElement('div');
    card.className = 'p-3 rounded-lg bg-surface-2 border ' + color + ' cursor-pointer hover:bg-surface-3 transition text-xs animate-pulse';
    card.innerHTML = '<div class="flex items-center justify-between mb-1"><span class="font-bold text-brand">' + icon + ' ' + humanize(event||cmd) + '</span><span class="text-gray-600">' + time + '</span></div>' +
      (aggType ? '<p class="text-gray-400">' + humanize(aggType) + (aggId ? ' #' + aggId : '') + '</p>' : '') +
      '<p class="text-gray-500 mt-1">' + humanize(cmd) + '</p>';
    card.onclick = function() {{
      card.classList.toggle('ring-1');
      card.classList.toggle('ring-brand/50');
    }};
    stream.insertBefore(card, stream.firstChild);
    setTimeout(() => card.classList.remove('animate-pulse'), 1000);
  }}
  function toggleCmd(btn) {{
    const form = btn.nextElementSibling;
    if (form) form.classList.toggle('hidden');
  }}
  function filterByStatus(el, status) {{
    const table = (el.closest('[data-domain-aggregate]') || el.parentElement.parentElement).querySelector('table') || document.querySelector('table');
    if (!table) return;
    const rows = table.querySelectorAll('tbody tr'), isActive = el.classList.contains('ring-2');
    el.parentElement.querySelectorAll('span').forEach(s => s.classList.remove('ring-2', 'ring-white'));
    if (isActive) {{ rows.forEach(r => r.style.display = ''); return; }}
    el.classList.add('ring-2', 'ring-white');
    rows.forEach(r => {{ r.style.display = r.textContent.toLowerCase().includes(status.toLowerCase()) ? '' : 'none'; }});
  }}
  function showDetail(row) {{
    const cells = row.querySelectorAll('td');
    const headers = row.closest('table').querySelectorAll('th');
    let fields = '';
    headers.forEach((h, i) => {{
      if (cells[i]) {{
        const label = h.textContent;
        const value = cells[i].textContent;
        fields += '<div><label class="block text-xs text-gray-400 mb-1">' + label + '</label><input value="' + value + '" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100"></div>';
      }}
    }});
    const modal = document.createElement('div');
    modal.className = 'fixed inset-0 bg-black/60 flex items-center justify-center z-50';
    modal.onclick = function(e) {{ if (e.target === modal) modal.remove(); }};
    modal.innerHTML = '<div class="bg-surface-2 rounded-xl p-6 max-w-lg w-full mx-4 border border-surface-3"><h3 class="text-lg font-bold text-brand mb-4">Record Detail</h3><div class="grid grid-cols-2 gap-3">' + fields + '</div><div class="mt-4 flex gap-3"><button onclick="this.closest(\'div.fixed\').remove()" class="px-4 py-1.5 bg-surface-3 rounded text-sm text-brand border border-surface-4">Close</button></div></div>';
    document.body.appendChild(modal);
  }}
  function showTab(tab) {{
    ['records','build'].forEach(t => {{
      document.getElementById('panel-'+t).classList.toggle('hidden', tab !== t);
      const btn = document.getElementById('tab-'+t);
      btn.classList.toggle('text-brand', tab === t);
      btn.classList.toggle('border-brand', tab === t);
      btn.classList.toggle('text-gray-400', tab !== t);
      btn.classList.toggle('border-transparent', tab !== t);
    }});
  }}
  function searchTable(input) {{
    const table = input.closest('div').parentElement.querySelector('table');
    if (!table) return;
    const query = input.value.toLowerCase();
    table.querySelectorAll('tbody tr').forEach(row => {{
      row.style.display = row.textContent.toLowerCase().includes(query) ? '' : 'none';
    }});
  }}
  {help_script}
  function sortTable(th) {{
    const table = th.closest('table');
    const idx = Array.from(th.parentElement.children).indexOf(th);
    const rows = Array.from(table.querySelectorAll('tbody tr'));
    const asc = th.dataset.sort !== 'asc';
    rows.sort((a, b) => {{
      const va = a.children[idx]?.textContent || '';
      const vb = b.children[idx]?.textContent || '';
      return asc ? va.localeCompare(vb) : vb.localeCompare(va);
    }});
    th.dataset.sort = asc ? 'asc' : 'desc';
    const tbody = table.querySelector('tbody');
    rows.forEach(r => tbody.appendChild(r));
    th.parentElement.querySelectorAll('th').forEach(t => t.textContent = t.textContent.replace(/ ▲| ▼/g, ''));
    th.textContent += asc ? ' ▲' : ' ▼';
  }}
  </script>
</head>
<body class="h-full bg-surface-0 text-gray-100">
  <div class="page-blob" style="width:500px;height:500px;top:5%;left:20%;background:#ffe400;animation:blob-drift-1 25s ease-in-out infinite"></div>
  <div class="page-blob" style="width:400px;height:400px;top:60%;right:10%;background:#ef4444;animation:blob-drift-2 30s ease-in-out infinite"></div>
  <div class="page-blob" style="width:450px;height:450px;bottom:10%;left:50%;background:#22c55e;animation:blob-drift-1 35s ease-in-out infinite reverse"></div>
  <div class="page-blob" style="width:350px;height:350px;top:30%;right:40%;background:#3b82f6;animation:blob-drift-2 28s ease-in-out infinite"></div>
  <div class="page-blob" style="width:400px;height:400px;bottom:30%;left:10%;background:#ffffff;animation:blob-drift-1 32s ease-in-out infinite reverse"></div>
  <div class="flex h-full relative z-10">
    <aside class="w-64 bg-surface-1 border-r border-surface-3 flex flex-col fixed h-full overflow-y-auto">
      <div class="p-6">
        <a href="/" class="text-xl font-bold text-brand hover:text-brand-dim transition">{app_name}</a>
        <p class="text-xs text-gray-500 mt-1">{app_subtitle}</p>
      </div>
      <nav class="flex-1 px-4 pb-4 space-y-1">
        {sidebar_html}
      </nav>
      <div class="p-4 border-t border-gray-800">
        <p class="text-xs text-gray-600 text-center">Empowered by Hecks</p>
      </div>
    </aside>
    <main class="flex-1 ml-64 mr-72 overflow-y-auto flex flex-col min-h-full">
      <div class="p-8 max-w-6xl flex-1">
        {main_html}
      </div>
    </main>
    <aside class="w-72 bg-surface-1 border-l border-surface-3 fixed right-0 h-full overflow-y-auto flex flex-col">
      <div class="p-4 border-b border-surface-3">
        <h3 class="text-sm font-bold text-gray-400 uppercase tracking-wider">⚡ Event Stream</h3>
      </div>
      <div id="event-stream" class="flex-1 p-4 space-y-2 overflow-y-auto">
        <p class="text-xs text-gray-600 italic">Dispatch a command to see events flow...</p>
      </div>
    </aside>
  </div>
</body>
</html>"#,
        title = title,
        app_name = app_name,
        app_subtitle = app_subtitle,
        sidebar_html = sidebar_html,
        main_html = main_html,
        help_script = help_script,
    )
}

/// Delegate sidebar generation to html_sidebar module
pub fn sidebar_links(domains: &[(String, usize)], active: Option<&str>) -> String {
    super::html_sidebar::sidebar_links(domains, active)
}

/// Return an emoji icon for a domain based on keyword matching
pub fn domain_icon(name: &str) -> &'static str {
    super::html_icons::domain_icon(name)
}

/// Return an emoji icon for an aggregate/module based on keyword matching
pub fn module_icon(name: &str) -> &'static str {
    super::html_icons::module_icon(name)
}

/// Convert snake_case or PascalCase to Title Case display name
pub fn display_name(name: &str) -> String {
    let (mut words, mut cur) = (Vec::new(), String::new());
    for ch in name.chars() {
        if ch == '_' { if !cur.is_empty() { words.push(cur.clone()); cur.clear(); } }
        else if ch.is_uppercase() && !cur.is_empty() {
            words.push(cur.clone()); cur.clear(); cur.push(ch);
        } else if cur.is_empty() { cur.push(ch.to_uppercase().next().unwrap()); }
        else { cur.push(ch); }
    }
    if !cur.is_empty() { words.push(cur); }
    words.join(" ")
}

/// Escape HTML special characters
pub fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
