module Hecks
  module Projections
    module Glossary
      module Html
        # The page around the sections: the document shell, the navigation rail and the front
        # matter.
        module Page
          # The document; `@@NAME@@` markers are filled in by `fill`.
          SHELL = <<~HTML.freeze
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>@@TITLE@@</title>
            <link rel="stylesheet" href="@@FONTS@@">
            <script src="@@MERMAID@@"></script>
            <style>
            @@CSS@@
            </style>
            </head>
            <body>
            <div class="page">
            @@RAIL@@
            <main>
            @@FRONT@@
            @@SECTIONS@@
            </main>
            </div>
            <script>
            @@JS@@
            </script>
            </body>
            </html>
          HTML

          # The navigation rail; `@@NAME@@` markers are filled in by `fill`.
          RAIL = <<~HTML.freeze
            <nav class="rail" aria-label="Sections">
            <p class="domain">@@DOMAIN@@</p>
            <p class="sub">Glossary</p>
            <input type="search" placeholder="Find a term" aria-label="Find a term" autocomplete="off">
            <p class="count"></p>
            <ol>
            @@ITEMS@@
            </ol>
            </nav>
          HTML

          module_function

          # @param title [String] the document's title
          # @param sections [Array<Hash>] the front matter, then each section
          # @param slugs [Hash] each heading's slug
          # @return [String] the whole page
          def page(title, sections, slugs)
            front, *rest = sections
            fill(SHELL, "TITLE" => Html.escape(title), "FONTS" => Html::FONTS, "MERMAID" => Html::MERMAID,
                        "CSS" => Html.asset("page.css"), "RAIL" => rail(title, rest, slugs),
                        "FRONT" => front_matter(front[:blocks]),
                        "SECTIONS" => rest.map { |section| Sections.section_html(section, slugs) }.join("\n"),
                        "JS" => Html.asset("page.js"))
          end

          # Fills each `@@NAME@@` marker in one pass, so a value is never itself searched for
          # markers.
          def fill(template, values)
            template.gsub(/@@(\w+)@@/) { values.fetch(Regexp.last_match(1)) }
          end

          def rail(title, sections, slugs)
            domain = title.split(" — ").first
            items = sections.map do |section|
              heading = section[:heading]
              %(<li><a href="##{slugs[heading]}">#{Html.inline(heading.text)}</a></li>)
            end
            fill(RAIL, "DOMAIN" => Html.escape(domain), "ITEMS" => items.join("\n"))
          end

          def front_matter(blocks)
            ["<header>", *blocks.filter_map { |block| front_part(block) }, "</header>"].join("\n")
          end

          def front_part(block)
            case block.type
            when :heading   then "<h1>#{Html.inline(block.text.split(" — ").first)}</h1>"
            when :quote     then "<p class=\"vision\">#{Html.inline(block.text)}</p>"
            when :paragraph then "<p class=\"lede\">#{Html.inline(block.text)}</p>"
            when :mermaid   then Html.figure(block, "How it all fits together")
            end
          end
        end
      end
    end
  end
end
