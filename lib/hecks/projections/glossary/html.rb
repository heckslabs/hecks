require_relative "../../forms/html"

module Hecks
  module Projections
    module Glossary
      # Renders `glossary.md` into a self-contained HTML page with a navigation rail.
      # A subset renderer for the constructs the projector emits, not a Markdown library.
      module Html
        Block = Struct.new(:type, :text, :items, :level, keyword_init: true)

        FONTS   = "https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;" \
                  "0,6..72,600;1,6..72,400&family=Instrument+Sans:wght@400;500;600&display=swap".freeze
        MERMAID = "https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js".freeze

        module_function

        # Renders `glossary.md`'s Markdown source as a self-contained HTML page.
        # Reads only the Markdown, never the bluebook, so the two cannot drift.
        def render(markdown)
          blocks = parse(markdown)
          slugs  = heading_slugs(blocks)
          title  = blocks.find { |block| block.type == :heading && block.level == 1 }&.text.to_s
          sections = split_sections(blocks)
          page(title, sections, slugs)
        end

        # Parses the Markdown subset the glossary projector emits into blocks.
        def parse(markdown)
          lines  = markdown.lines.map(&:chomp)
          blocks = []
          index  = 0
          while index < lines.size
            line = lines[index]
            if line.start_with?("```mermaid")
              block, index = fence(lines, index)
              blocks << block
            elsif (heading = line.match(/\A(\#{1,3}) (.+)\z/))
              blocks << Block.new(type: :heading, text: heading[2], level: heading[1].size)
              index += 1
            elsif line.start_with?("> ")
              blocks << Block.new(type: :quote, text: line[2..])
              index += 1
            elsif line.start_with?("- ")
              items, index = run(lines, index) { |text| text.start_with?("- ") }
              blocks << Block.new(type: :list, items: items.map { |item| item[2..] })
            elsif line.strip.empty?
              index += 1
            else
              para, index = run(lines, index) { |text| !text.strip.empty? }
              blocks << Block.new(type: :paragraph, text: para.join(" "))
            end
          end
          blocks
        end

        # The mermaid block opened at `index`, and the line index just past its closing fence.
        def fence(lines, index)
          close = ((index + 1)...lines.size).find { |at| lines[at] == "```" } || lines.size
          [Block.new(type: :mermaid, text: lines[(index + 1)...close].join("\n")), close + 1]
        end

        # The consecutive lines from `index` that satisfy the block, and the index past them.
        def run(lines, index)
          taken = []
          while index < lines.size && yield(lines[index])
            taken << lines[index]
            index += 1
          end
          [taken, index]
        end

        # GitHub's slugs for these headings, so links the Markdown carries land here too.
        # Keyed by identity: a Struct compares by members, so two "### Open" headings in
        # different sections would collide and `#open` would have nothing to land on.
        def heading_slugs(blocks)
          seen  = Hash.new(0)
          slugs = {}.compare_by_identity
          blocks.select { |block| block.type == :heading }.each do |block|
            base = Slugs.github(block.text)
            seen[base] += 1
            slugs[block] = seen[base] == 1 ? base : "#{base}-#{seen[base] - 1}"
          end
          slugs
        end

        # Blocks before the first `##` are front matter (heading nil); each `##` opens a section.
        def split_sections(blocks)
          sections = [{ heading: nil, blocks: [] }]
          blocks.each do |block|
            sections << { heading: block, blocks: [] } if block.type == :heading && block.level == 2
            sections.last[:blocks] << block
          end
          sections
        end

        def page(title, sections, slugs)
          front, *rest = sections
          <<~HTML
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{escape(title)}</title>
            <link rel="stylesheet" href="#{FONTS}">
            <script src="#{MERMAID}"></script>
            <style>
            #{asset("page.css")}
            </style>
            </head>
            <body>
            <div class="page">
            #{rail(title, rest, slugs)}
            <main>
            #{front_matter(front[:blocks])}
            #{rest.map { |section| section_html(section, slugs) }.join("\n")}
            </main>
            </div>
            <script>
            #{asset("page.js")}
            </script>
            </body>
            </html>
          HTML
        end

        def rail(title, sections, slugs)
          domain = title.split(" — ").first
          items = sections.map do |section|
            heading = section[:heading]
            %(<li><a href="##{slugs[heading]}">#{inline(heading.text)}</a></li>)
          end
          <<~HTML
            <nav class="rail" aria-label="Sections">
            <p class="domain">#{escape(domain)}</p>
            <p class="sub">Glossary</p>
            <input type="search" placeholder="Find a term" aria-label="Find a term" autocomplete="off">
            <p class="count"></p>
            <ol>
            #{items.join("\n")}
            </ol>
            </nav>
          HTML
        end

        def front_matter(blocks)
          parts = ["<header>"]
          blocks.each do |block|
            case block.type
            when :heading   then parts << "<h1>#{inline(block.text.split(" — ").first)}</h1>"
            when :quote     then parts << "<p class=\"vision\">#{inline(block.text)}</p>"
            when :paragraph then parts << "<p class=\"lede\">#{inline(block.text)}</p>"
            when :mermaid   then parts << figure(block, "How it all fits together")
            end
          end
          parts << "</header>"
          parts.join("\n")
        end

        # Each `###` opens an article running to the next. A bold-only paragraph
        # captions whatever figure or list follows it.
        def section_html(section, slugs)
          heading = section[:heading]
          state = { parts: [%(<section id="#{slugs[heading]}">), "<h2>#{inline(heading.text)}</h2>"],
                    caption: nil, in_terms: false }
          section[:blocks].drop(1).each { |block| section_block(block, state, slugs) }
          state[:parts] << "</article></div>" if state[:in_terms]
          state[:parts] << "</section>"
          state[:parts].join("\n")
        end

        # Renders one block into `state[:parts]`, mutating `state`.
        def section_block(block, state, slugs)
          parts = state[:parts]
          case block.type
          when :heading
            parts << (state[:in_terms] ? "</article>" : "<div class=\"terms\">")
            parts << %(<article class="term" id="#{slugs[block]}">) << "<h3>#{inline(block.text)}</h3>"
            state[:in_terms] = true
          when :mermaid
            parts << figure(block, state.delete(:caption))
          when :list
            caption = state.delete(:caption)
            parts << "<p class=\"caption\">#{escape(caption)}</p>" if caption
            parts << "<ul class=\"rules\">#{block.items.map { |item| "<li>#{inline(item)}</li>" }.join}</ul>"
          when :quote
            parts << "<p class=\"about\">#{inline(block.text)}</p>"
          when :paragraph
            paragraph(block.text, state)
          end
        end

        def paragraph(text, state)
          if text.match?(/\A\*\*[^*]+\*\*\z/)
            state[:caption] = text.delete("*")
          else
            klass = text.start_with?("Always true:") ? " class=\"rule\"" : ""
            state[:parts] << "<p#{klass}>#{inline(text)}</p>"
          end
        end

        def figure(block, caption)
          parts = ["<figure>"]
          parts << "<figcaption>#{escape(caption)}</figcaption>" if caption
          parts << "<pre class=\"mermaid\">#{escape(block.text)}</pre>" << "</figure>"
          parts.join("\n")
        end

        def escape(text) = Forms::Escape.html(text)

        # Escapes first so prose never becomes a tag, then converts links, bold and italic.
        def inline(text)
          escape(text)
            .gsub(/\[([^\]]+)\]\(#([^)]+)\)/) { %(<a href="##{Regexp.last_match(2)}">#{Regexp.last_match(1)}</a>) }
            .gsub(/\*\*(.+?)\*\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }
            .gsub(/\*(.+?)\*/) { "<em>#{Regexp.last_match(1)}</em>" }
        end

        def asset(name) = File.read(File.join(__dir__, name))
      end
    end
  end
end
