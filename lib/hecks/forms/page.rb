require_relative "html"

module Hecks
  module Forms
    # The one HTML shell every page in this app renders inside — nav,
    # typography, form/table/badge styles, all inline (no CDN, no build
    # step: this ships inside the `hecks` gem, and a project that
    # embeds it gets one dependency-free response per request). Themed via
    # `prefers-color-scheme` alone; nothing here reads a cookie or a query
    # param for it, so it is never wrong for the browser rendering it.
    module Page
      def self.render(title:, body:, breadcrumbs: [])
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{Escape.html(title)} · hecks forms</title>
          <style>#{STYLE}</style>
          </head>
          <body>
          <header class="site-header">
            <a class="brand" href="/">hecks forms</a>
            #{breadcrumbs_html(breadcrumbs)}
          </header>
          <main>
          #{body}
          </main>
          <footer class="site-footer">
            <p>Generated straight from the loaded bluebook IR — nothing here is hand-authored per page. See <code>docs/command-form-and-query-form-bluebook.md</code>.</p>
          </footer>
          <script>#{SCRIPT}</script>
          </body>
          </html>
        HTML
      end

      def self.breadcrumbs_html(crumbs)
        return "" if crumbs.empty?

        items = crumbs.map do |label, href|
          href ? %(<a href="#{Escape.attr(href)}">#{Escape.html(label)}</a>) : %(<span aria-current="page">#{Escape.html(label)}</span>)
        end
        %(<nav class="breadcrumbs" aria-label="Breadcrumb">#{items.join(' <span class="sep">/</span> ')}</nav>)
      end

      STYLE = <<~CSS
        :root {
          --bg: #fbfaf8; --surface: #ffffff; --border: #e2ddd3; --text: #24211c;
          --muted: #6b6355; --accent: #8a5a2b; --accent-contrast: #fff8ef;
          --danger-bg: #fdeceb; --danger-border: #e2a49c; --danger-text: #7a2419;
          --focus: #2b6cb0; --code-bg: #f1ede4; --radius: 8px;
          --mono: "SF Mono", "JetBrains Mono", ui-monospace, Menlo, Consolas, monospace;
          --sans: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #17140f; --surface: #201c15; --border: #3a3327; --text: #ece6d9;
            --muted: #a89d87; --accent: #d99a52; --accent-contrast: #241a0c;
            --danger-bg: #341613; --danger-border: #7a352b; --danger-text: #f3a99c;
            --focus: #6ab0ff; --code-bg: #241f17;
          }
        }
        * { box-sizing: border-box; }
        body { background: var(--bg); color: var(--text); font-family: var(--sans); margin: 0; line-height: 1.5; }
        a { color: var(--accent); }
        a:focus-visible, button:focus-visible, input:focus-visible, select:focus-visible, textarea:focus-visible {
          outline: 2px solid var(--focus); outline-offset: 2px;
        }
        .site-header { display: flex; align-items: baseline; gap: 1rem; padding: .9rem 1.5rem;
          border-bottom: 1px solid var(--border); background: var(--surface); flex-wrap: wrap; }
        .brand { font-family: var(--mono); font-weight: 600; text-decoration: none; color: var(--text); }
        .breadcrumbs { font-size: .9rem; color: var(--muted); }
        .breadcrumbs .sep { padding: 0 .3rem; }
        main { max-width: 46rem; margin: 0 auto; padding: 2rem 1.5rem 4rem; }
        .site-footer { max-width: 46rem; margin: 0 auto; padding: 1rem 1.5rem 3rem; color: var(--muted); font-size: .82rem; }
        h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
        h2 { font-size: 1.1rem; margin: 2rem 0 .6rem; }
        .goal { color: var(--muted); margin: 0 0 1rem; }
        .badge { display: inline-block; font-family: var(--mono); font-size: .72rem; padding: .15rem .5rem;
          border-radius: 999px; border: 1px solid var(--border); color: var(--muted); margin: 0 .3rem .3rem 0; }
        .badge.role { color: var(--accent); border-color: var(--accent); }
        .callout { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
          padding: .8rem 1rem; margin: 0 0 1.2rem; font-size: .92rem; }
        .callout ul { margin: .3rem 0 0; padding-left: 1.2rem; }
        .error-banner { background: var(--danger-bg); border: 1px solid var(--danger-border); color: var(--danger-text);
          border-radius: var(--radius); padding: .8rem 1rem; margin: 0 0 1.2rem; }
        .error-banner p { margin: 0; }
        fieldset { border: 1px solid var(--border); border-radius: var(--radius); margin: 0 0 1.1rem; padding: .8rem 1rem 1rem; }
        legend { font-size: .85rem; color: var(--muted); padding: 0 .4rem; }
        .field { margin: 0 0 1.1rem; }
        .field > label { display: block; font-weight: 600; font-size: .9rem; margin-bottom: .3rem; }
        .field .required-mark { color: var(--accent); }
        .field .help { display: block; color: var(--muted); font-size: .8rem; margin-top: .3rem; }
        .field input[type=text], .field input[type=email], .field input[type=url], .field input[type=tel],
        .field input[type=number], .field select, .field textarea {
          width: 100%; padding: .5rem .6rem; border: 1px solid var(--border); border-radius: var(--radius);
          background: var(--surface); color: var(--text); font: inherit;
        }
        .field textarea { min-height: 4.5rem; font-family: var(--mono); font-size: .85rem; }
        .radio-group { display: flex; flex-wrap: wrap; gap: .3rem 1rem; }
        .radio-group label { font-weight: 400; display: flex; align-items: center; gap: .35rem; }
        .checkbox-row { display: flex; align-items: center; gap: .5rem; }
        button, .button { font: inherit; border-radius: var(--radius); border: 1px solid var(--accent);
          background: var(--accent); color: var(--accent-contrast); padding: .55rem 1.1rem; cursor: pointer; }
        button.secondary, .button.secondary { background: transparent; color: var(--text); border-color: var(--border); }
        button.copy { font-size: .75rem; padding: .2rem .5rem; }
        table { width: 100%; border-collapse: collapse; font-size: .88rem; }
        .table-scroll { overflow-x: auto; margin: 0 0 1.2rem; }
        th, td { text-align: left; padding: .45rem .6rem; border-bottom: 1px solid var(--border); white-space: nowrap; }
        thead th { color: var(--muted); font-weight: 600; position: sticky; top: 0; background: var(--bg); }
        tbody tr:hover { background: var(--surface); }
        code, pre, .mono { font-family: var(--mono); font-size: .82rem; }
        pre { background: var(--code-bg); border-radius: var(--radius); padding: .8rem 1rem; overflow-x: auto; margin: 0; }
        .link-row { display: flex; gap: .5rem; align-items: center; margin: 0 0 .8rem; }
        .link-row code { flex: 1; overflow-x: auto; padding: .4rem .6rem; background: var(--code-bg); border-radius: var(--radius); }
        .example-links { display: flex; flex-wrap: wrap; gap: .4rem; margin: 0 0 1rem; }
        .example-links a { border: 1px solid var(--border); border-radius: 999px; padding: .25rem .7rem;
          text-decoration: none; font-family: var(--mono); font-size: .82rem; }
        details.inspect { margin: 2rem 0 0; border-top: 1px dashed var(--border); padding-top: 1rem; }
        details.inspect summary { cursor: pointer; color: var(--muted); font-size: .85rem; }
        .verb-list { list-style: none; padding: 0; margin: 0; }
        .verb-list li { border-bottom: 1px solid var(--border); }
        .verb-list a { display: flex; justify-content: space-between; gap: 1rem; padding: .7rem .2rem;
          text-decoration: none; color: var(--text); }
        .verb-list .kind { color: var(--muted); font-family: var(--mono); font-size: .78rem; }
        .actions { display: flex; flex-wrap: wrap; gap: .5rem; margin: .6rem 0 1.4rem; }
      CSS

      # Decorative only — every form here already works with JS disabled
      # (plain `<form method=post>`/`method=get`), matching this repo's own
      # "no ERB, nothing scripted" bar for the domain layer itself.
      SCRIPT = <<~JS
        document.addEventListener("click", (event) => {
          const button = event.target.closest("[data-copy]");
          if (!button) return;
          const text = document.querySelector(button.getAttribute("data-copy"))?.textContent ?? "";
          navigator.clipboard?.writeText(text.trim());
          const original = button.textContent;
          button.textContent = "copied";
          setTimeout(() => { button.textContent = original; }, 1200);
        });
        document.querySelectorAll("[data-money-cents]").forEach((input) => {
          const preview = document.querySelector(input.getAttribute("data-money-cents"));
          if (!preview) return;
          const update = () => {
            const cents = parseInt(input.value, 10);
            preview.textContent = Number.isFinite(cents) ? "= " + (cents / 100).toFixed(2) : "";
          };
          input.addEventListener("input", update);
          update();
        });
      JS
    end
  end
end
