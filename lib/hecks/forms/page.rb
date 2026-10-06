require_relative "html"
require_relative "page_assets"
require_relative "page_script"

module Hecks
  module Forms
    # The HTML shell every page renders inside, with styles and script inline.
    # Themed by `prefers-color-scheme` alone.
    module Page
      # Wraps one page's own body HTML in the shared shell: doctype, head, nav, footer,
      # inline styles and script.
      #
      # @param title [String] the page title, escaped into `<title>` and the browser tab
      # @param body [String] the page's own body markup, inserted unescaped inside `<main>`
      # @param breadcrumbs [Array<Array(String, String), Array(String, nil)>] each
      #   `[label, href]` pair, in order; the last pair's `href` should be `nil` for the
      #   current page
      # @return [String] the complete HTML document
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

      # Renders the breadcrumb trail as a `<nav>`, each crumb a link except the last.
      #
      # @param crumbs [Array<Array(String, String), Array(String, nil)>] each
      #   `[label, href]` pair; a `nil` href renders as the current, unlinked page
      # @return [String] the `<nav>` markup, HTML-escaped; `""` when `crumbs` is empty
      def self.breadcrumbs_html(crumbs)
        return "" if crumbs.empty?

        items = crumbs.map do |label, href|
          if href
            %(<a href="#{Escape.attr(href)}">#{Escape.html(label)}</a>)
          else
            %(<span aria-current="page">#{Escape.html(label)}</span>)
          end
        end
        %(<nav class="breadcrumbs" aria-label="Breadcrumb">#{items.join(' <span class="sep">/</span> ')}</nav>)
      end
    end
  end
end
