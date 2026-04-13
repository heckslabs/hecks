//! Shared HTML layout — app shell, head, sidebar, footer
//!
//! Provides the Tailwind-styled page wrapper used by both
//! the index page and individual domain pages.
//!
//! Usage:
//!   let page = wrap_page("Title", &sidebar, &content);

/// Wrap content in the full app shell with sidebar
pub fn wrap_page(title: &str, sidebar_html: &str, main_html: &str) -> String {
    let app_name = title;
    let app_subtitle = "Dashboard";
    let core_script = super::html_scripts::core_script();
    let help_script = super::html_help::help_script();
    let wizard_script = super::html_wizard::wizard_script();
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
    body, h1, h2, h3 {{ font-family: 'Cabin', sans-serif; }}
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
    details[open] > div {{ animation: slideDown 0.3s ease-out; }}
    @keyframes slideDown {{ from {{ opacity: 0; max-height: 0; transform: translateY(-12px); }} to {{ opacity: 1; max-height: 5000px; transform: translateY(0); }} }}

    /* Slideable panels and tabs */
    .tab-panel {{ transition: opacity 0.3s ease, transform 0.3s ease; }}
    .tab-panel.entering {{ opacity: 0; transform: translateX(20px); }}

    /* Module cards slide + lift */
    details.bg-surface-2 {{ transition: transform 0.2s ease, box-shadow 0.2s ease; }}
    details.bg-surface-2:hover {{ transform: translateY(-2px); box-shadow: 0 8px 24px rgba(0,0,0,0.3); }}

    /* Command forms slide open */
    details[data-domain-command] > div {{ transition: max-height 0.3s ease, opacity 0.25s ease; overflow: hidden; }}

    /* Sidebar items slide in staggered */
    nav a {{ opacity: 0; animation: sidebarSlide 0.3s ease forwards; }}
    @keyframes sidebarSlide {{ from {{ opacity: 0; transform: translateX(-12px); }} to {{ opacity: 1; transform: translateX(0); }} }}
    nav a:nth-child(1) {{ animation-delay: 0.05s; }}
    nav a:nth-child(2) {{ animation-delay: 0.1s; }}
    nav a:nth-child(3) {{ animation-delay: 0.15s; }}
    nav a:nth-child(4) {{ animation-delay: 0.2s; }}
    nav a:nth-child(5) {{ animation-delay: 0.25s; }}
    nav a:nth-child(6) {{ animation-delay: 0.3s; }}
    nav a:nth-child(7) {{ animation-delay: 0.35s; }}
    nav a:nth-child(8) {{ animation-delay: 0.4s; }}

    /* Event cards slide in from right */
    #event-stream > div {{ animation: eventSlide 0.3s ease-out; }}
    @keyframes eventSlide {{ from {{ opacity: 0; transform: translateX(20px); }} to {{ opacity: 1; transform: translateX(0); }} }}
    @keyframes blob-drift-1 {{ 0% {{ transform: translate(0,0) scale(1); }} 50% {{ transform: translate(-5vw,8vh) scale(0.9); }} 100% {{ transform: translate(0,0) scale(1); }} }}
    @keyframes blob-drift-2 {{ 0% {{ transform: translate(0,0) scale(1); }} 50% {{ transform: translate(7vw,-10vh) scale(0.88); }} 100% {{ transform: translate(0,0) scale(1); }} }}
    .page-blob {{
      position: fixed; border-radius: 50%; filter: blur(100px);
      opacity: 0.06; pointer-events: none; will-change: transform;
    }}
  </style>
  <script>
  {core_script}
  {help_script}
  {wizard_script}
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
        core_script = core_script,
        help_script = help_script,
        wizard_script = wizard_script,
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

/// Convert snake_case or PascalCase to Title Case display name.
/// Infers acronyms from consecutive uppercase runs: DCSource → DC Source,
/// USBOutlets → USB Outlets, HTMLPage → HTML Page.
pub fn display_name(name: &str) -> String {
    let chars: Vec<char> = name.chars().collect();
    let mut words: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut i = 0;

    while i < chars.len() {
        let ch = chars[i];

        if ch == '_' {
            if !cur.is_empty() { words.push(cur.clone()); cur.clear(); }
            i += 1;
            continue;
        }

        if ch.is_uppercase() {
            // Count how many uppercase chars in a row
            let start = i;
            while i < chars.len() && chars[i].is_uppercase() { i += 1; }
            let run_len = i - start;

            if run_len == 1 {
                // Single uppercase = new word boundary (e.g. the C in "Create")
                if !cur.is_empty() { words.push(cur.clone()); cur.clear(); }
                cur.push(chars[start]);
                // Consume the lowercase tail: reate
                while i < chars.len() && chars[i].is_lowercase() {
                    cur.push(chars[i]);
                    i += 1;
                }
            } else {
                // Multiple uppercase = acronym
                if !cur.is_empty() { words.push(cur.clone()); cur.clear(); }
                if i < chars.len() && chars[i].is_lowercase() {
                    // Last uppercase belongs to next word: HTMLPage → HTML + Page
                    let acronym: String = chars[start..i-1].iter().collect();
                    words.push(acronym);
                    cur.push(chars[i-1]);
                    i += 0; // don't advance — outer loop will consume lowercase
                    // Consume the lowercase tail
                    while i < chars.len() && chars[i].is_lowercase() {
                        cur.push(chars[i]);
                        i += 1;
                    }
                } else {
                    // All uppercase at end: parseJSON → JSON
                    let acronym: String = chars[start..i].iter().collect();
                    words.push(acronym);
                }
            }
        } else {
            // Lowercase at start of string
            if cur.is_empty() { cur.push(ch.to_uppercase().next().unwrap()); }
            else { cur.push(ch); }
            i += 1;
        }
    }
    if !cur.is_empty() { words.push(cur); }
    words.join(" ")
}

/// Escape HTML special characters
pub fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
