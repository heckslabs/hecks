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
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>body {{ font-family: 'Inter', sans-serif; }}</style>
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
    const section = el.closest('[data-domain-aggregate]') || el.parentElement.parentElement;
    const table = section.querySelector('table') || document.querySelector('table');
    if (!table) return;
    const rows = table.querySelectorAll('tbody tr');
    const isActive = el.classList.contains('ring-2');
    // Reset all badges
    el.parentElement.querySelectorAll('span').forEach(s => s.classList.remove('ring-2', 'ring-white'));
    if (isActive) {{
      rows.forEach(r => r.style.display = '');
      return;
    }}
    el.classList.add('ring-2', 'ring-white');
    rows.forEach(r => {{
      const text = r.textContent.toLowerCase();
      r.style.display = text.includes(status.toLowerCase()) ? '' : 'none';
    }});
  }}
  </script>
</head>
<body class="h-full bg-gray-950 text-gray-100">
  <div class="flex h-full">
    <aside class="w-64 bg-gray-900 border-r border-gray-700 flex flex-col fixed h-full overflow-y-auto">
      <div class="p-6">
        <a href="/" class="text-xl font-bold text-white hover:text-blue-400 transition">{app_name}</a>
        <p class="text-xs text-gray-500 mt-1">{app_subtitle}</p>
      </div>
      <nav class="flex-1 px-4 pb-4 space-y-1">
        {sidebar_html}
      </nav>
      <div class="p-4 border-t border-gray-800">
        <p class="text-xs text-gray-600 text-center">Empowered by Hecks</p>
      </div>
    </aside>
    <main class="flex-1 ml-64 overflow-y-auto">
      <div class="p-8 max-w-6xl">
        {main_html}
      </div>
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

/// Generate sidebar nav links from domain names, highlighting active
pub fn sidebar_links(domains: &[(String, usize)], active: Option<&str>) -> String {
    let mut out = String::new();
    for (name, count) in domains {
        let active_class = if active == Some(name.as_str()) {
            "bg-gray-800 text-white"
        } else {
            "text-gray-400 hover:bg-gray-800 hover:text-white"
        };
        out.push_str(&format!(
            r#"<a href="/domains/{name}" data-domain-aggregate="{name}" class="flex items-center justify-between px-3 py-2 rounded-lg text-sm {active_class} transition">
  <span>{label}</span>
  <span class="text-xs text-gray-600">{count}</span>
</a>"#,
            name = name,
            label = display_name(name),
            count = count,
            active_class = active_class,
        ));
    }
    out
}

/// Convert snake_case domain name to Title Case display name
pub fn display_name(name: &str) -> String {
    name.split('_')
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                None => String::new(),
                Some(f) => f.to_uppercase().to_string() + c.as_str(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Escape HTML special characters
pub fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
