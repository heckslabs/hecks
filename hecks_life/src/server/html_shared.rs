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
    body::before {{
      content: '';
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: radial-gradient(ellipse at 20% 30%, rgba(255,228,0,0.03) 0%, transparent 50%),
                  radial-gradient(ellipse at 80% 70%, rgba(255,228,0,0.02) 0%, transparent 50%);
      pointer-events: none;
      z-index: 0;
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
      const span = form.querySelector('.cmd-result');
      span.textContent = r.ok ? 'Done — ' + (r.event || 'ok') : 'Error: ' + r.error;
      span.className = 'cmd-result text-xs ml-3 ' + (r.ok ? 'text-emerald-400' : 'text-red-400');
    }});
    return false;
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
  <div class="flex h-full">
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
    <main class="flex-1 ml-64 overflow-y-auto flex flex-col min-h-full">
      <div class="p-8 max-w-6xl flex-1">
        {main_html}
      </div>
      <footer class="p-4 text-center">
        <p class="text-xs text-gray-600">Empowered by Hecks</p>
      </footer>
    </main>
  </div>
</body>
</html>"#,
        title = title,
        app_name = app_name,
        app_subtitle = app_subtitle,
        sidebar_html = sidebar_html,
        main_html = main_html,
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

/// Convert snake_case domain name to Title Case display name
pub fn display_name(name: &str) -> String {
    // Split PascalCase and snake_case into words
    let mut words = Vec::new();
    let mut current = String::new();
    for ch in name.chars() {
        if ch == '_' {
            if !current.is_empty() { words.push(current.clone()); current.clear(); }
        } else if ch.is_uppercase() && !current.is_empty() {
            words.push(current.clone()); current.clear();
            current.push(ch);
        } else {
            if current.is_empty() { current.push(ch.to_uppercase().next().unwrap()); }
            else { current.push(ch); }
        }
    }
    if !current.is_empty() { words.push(current); }
    words.join(" ")
}

/// Escape HTML special characters
pub fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
