require_relative "../../forms/html"

module Hecks
  module Projections
    module Glossary
      # **The page, rendered from the markdown** — `html/index.html` is
      # `glossary.md` read back and dressed: a navigation rail built from
      # its `##` headings, each `###` a term entry, every ```mermaid fence
      # a diagram, every `[x](#y)` an in-page link. Nothing here reads
      # the bluebook; if the page shows it, the Markdown says it, so the
      # two cannot drift.
      #
      # A subset renderer, not a markdown library — the projector emits
      # a fixed handful of constructs (`Markdown`'s own header lists
      # them), and this reads exactly those. The Gemfile keeps every
      # dependency justified in its own comment; a full Markdown engine
      # for six constructs would not earn one.
      #
      # The look lives in page.css / page.js beside this file — read at
      # render time and inlined, so the page is one self-contained file.
      # The only things it fetches are the two typefaces (Google Fonts)
      # and Mermaid itself (cdnjs), which draws the diagrams in the
      # browser; without a network the diagrams show as their source.
      module Html
        Block = Struct.new(:type, :text, :items, :level, keyword_init: true)

        FONTS   = "https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;" \
                  "0,6..72,600;1,6..72,400&family=Instrument+Sans:wght@400;500;600&display=swap".freeze
        MERMAID = "https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js".freeze

        module_function

        # Renders `glossary.md`'s Markdown source as a self-contained HTML page.
        #
        # @param markdown [String] `glossary.md`'s own rendered Markdown source
        # @return [String] the complete `html/index.html` source
        def render(markdown)
          blocks = parse(markdown)
          slugs  = heading_slugs(blocks)
          title  = blocks.find { |block| block.type == :heading && block.level == 1 }&.text.to_s
          sections = split_sections(blocks)
          page(title, sections, slugs)
        end

        # ── reading the Markdown ─────────────────────────────────────────

        # Parses the subset of Markdown the glossary projector emits into
        # structured blocks.
        #
        # @param markdown [String] the Markdown source to parse
        # @return [Array<Block>] one block per heading, quote, list, mermaid
        #   fence, or paragraph, in document order
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

        # The mermaid source between the opening fence at `index` and its
        # closing one, and the index just past that.
        #
        # @param lines [Array<String>] the document's lines
        # @param index [Integer] the opening ` ```mermaid ` fence's line index
        # @return [Array(Block, Integer)] the parsed `:mermaid` block, and the line
        #   index just past its closing fence
        def fence(lines, index)
          close = ((index + 1)...lines.size).find { |at| lines[at] == "```" } || lines.size
          [Block.new(type: :mermaid, text: lines[(index + 1)...close].join("\n")), close + 1]
        end

        # The consecutive lines from `index` that satisfy the block, and
        # the index just past them.
        #
        # @param lines [Array<String>] the document's lines
        # @param index [Integer] the line index to start scanning from
        # @yieldparam text [String] one candidate line
        # @yieldreturn [Boolean] whether that line belongs to the run
        # @return [Array(Array<String>, Integer)] the consecutive matching lines, and
        #   the line index just past them
        def run(lines, index)
          taken = []
          while index < lines.size && yield(lines[index])
            taken << lines[index]
            index += 1
          end
          [taken, index]
        end

        # The same slugs GitHub would give these headings, in the same
        # order — so the links the Markdown carries land here too.
        #
        # Keyed by the block itself, not its value — a Struct compares by
        # members, so two "### Open" headings in different sections would
        # otherwise be one key, and the first would answer with the
        # second's "-1" slug, leaving `#open` with nothing to land on.
        #
        # @param blocks [Array<Block>] every parsed block, in document order
        # @return [Hash{Block => String}] each heading block, mapped to its GitHub-style
        #   slug, keyed by object identity
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

        # Everything before the first `##` is the front matter; each `##`
        # opens a section that runs to the next.
        #
        # @param blocks [Array<Block>] every parsed block, in document order
        # @return [Array<Hash{Symbol => Object}>] one Hash per section: `:heading`
        #   (the `Block`, or nil for the leading front matter) and `:blocks` (its
        #   own `Array<Block>`)
        def split_sections(blocks)
          sections = [{ heading: nil, blocks: [] }]
          blocks.each do |block|
            sections << { heading: block, blocks: [] } if block.type == :heading && block.level == 2
            sections.last[:blocks] << block
          end
          sections
        end

        # ── writing the page ─────────────────────────────────────────────

        # Renders the full HTML page shell around the navigation rail and content.
        #
        # @param title [String] the document's `#` heading text
        # @param sections [Array<Hash{Symbol => Object}>] every `##` section, as
        #   `split_sections` builds (the front matter excluded by the caller)
        # @param slugs [Hash{Block => String}] every heading block's own slug
        # @return [String] the complete HTML page source
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
            #{asset('page.css')}
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
            #{asset('page.js')}
            </script>
            </body>
            </html>
          HTML
        end

        # Renders the navigation rail: the domain name, a search box, and one
        # link per section.
        #
        # @param title [String] the document's `#` heading text, `"Domain — Glossary"`
        # @param sections [Array<Hash{Symbol => Object}>] every `##` section (the
        #   front matter excluded)
        # @param slugs [Hash{Block => String}] every heading block's own slug
        # @return [String] the rail's HTML source
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

        # Renders the page's `<header>`: the title, vision, lede, and overview diagram.
        #
        # @param blocks [Array<Block>] the front matter's own blocks
        # @return [String] the header's HTML source
        def front_matter(blocks)
          parts = ["<header>"]
          blocks.each do |block|
            case block.type
            when :heading   then parts << "<h1>#{inline(block.text.split(' — ').first)}</h1>"
            when :quote     then parts << "<p class=\"vision\">#{inline(block.text)}</p>"
            when :paragraph then parts << "<p class=\"lede\">#{inline(block.text)}</p>"
            when :mermaid   then parts << figure(block, "How it all fits together")
            end
          end
          parts << "</header>"
          parts.join("\n")
        end

        # A section is its heading, then its opening (lede, diagrams, the
        # rules list), then its terms — each `###` opens an article that
        # runs to the next. A bold-only paragraph is the caption of
        # whatever figure or list follows it.
        #
        # @param section [Hash{Symbol => Object}] one `##` section, as `split_sections`
        #   builds
        # @param slugs [Hash{Block => String}] every heading block's own slug
        # @return [String] the section's `<section>` HTML source
        def section_html(section, slugs)
          heading = section[:heading]
          state = { parts: [%(<section id="#{slugs[heading]}">), "<h2>#{inline(heading.text)}</h2>"],
                    caption: nil, in_terms: false }
          section[:blocks].drop(1).each { |block| section_block(block, state, slugs) }
          state[:parts] << "</article></div>" if state[:in_terms]
          state[:parts] << "</section>"
          state[:parts].join("\n")
        end

        # Renders one block into `state[:parts]`, mutating `state` as it goes.
        #
        # @param block [Block] the block to render
        # @param state [Hash{Symbol => Object}] the section's own render state:
        #   `:parts` (the growing `Array<String>` of HTML), `:caption` (a pending
        #   bold-only paragraph's text, or nil), `:in_terms` (whether a `###` term
        #   article is currently open)
        # @param slugs [Hash{Block => String}] every heading block's own slug
        # @return [void]
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
            parts << "<p class=\"caption\">#{escape(state[:caption])}</p>" if state.delete(:caption)
            parts << "<ul class=\"rules\">#{block.items.map { |item| "<li>#{inline(item)}</li>" }.join}</ul>"
          when :quote
            parts << "<p class=\"about\">#{inline(block.text)}</p>"
          when :paragraph
            paragraph(block.text, state)
          end
        end

        # Renders one paragraph, either capturing it as a pending caption (a
        # bold-only line) or appending it to `state[:parts]`.
        #
        # @param text [String] the paragraph's own text
        # @param state [Hash{Symbol => Object}] the section's own render state (see
        #   `section_block`); `:caption` and `:parts` may be mutated
        # @return [void]
        def paragraph(text, state)
          if text.match?(/\A\*\*[^*]+\*\*\z/)
            state[:caption] = text.delete("*")
          else
            klass = text.start_with?("Always true:") ? " class=\"rule\"" : ""
            state[:parts] << "<p#{klass}>#{inline(text)}</p>"
          end
        end

        # Renders a mermaid block as a `<figure>`, with an optional caption.
        #
        # @param block [Block] the `:mermaid` block to render
        # @param caption [String, nil] the figure's caption text, or nil for none
        # @return [String] the `<figure>`'s HTML source
        def figure(block, caption)
          parts = ["<figure>"]
          parts << "<figcaption>#{escape(caption)}</figcaption>" if caption
          parts << "<pre class=\"mermaid\">#{escape(block.text)}</pre>" << "</figure>"
          parts.join("\n")
        end

        # ── inline text ──────────────────────────────────────────────────

        # Escapes text for HTML.
        #
        # @param text [Object, nil] the value to escape, rendered with `to_s`
        # @return [String] `text`, HTML-escaped
        def escape(text) = Forms::Escape.html(text)

        # Escape first, so nothing in the prose ever becomes a tag; then
        # the three inline forms the Markdown uses, on the escaped text.
        #
        # @param text [String] the inline text to render
        # @return [String] `text`, HTML-escaped, with `[x](#y)` links, `**bold**` and
        #   `*italic*` spans converted to their HTML equivalents
        def inline(text)
          escape(text)
            .gsub(/\[([^\]]+)\]\(#([^)]+)\)/) { %(<a href="##{Regexp.last_match(2)}">#{Regexp.last_match(1)}</a>) }
            .gsub(/\*\*(.+?)\*\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }
            .gsub(/\*(.+?)\*/) { "<em>#{Regexp.last_match(1)}</em>" }
        end

        # Reads one static asset file from beside this file.
        #
        # @param name [String] the asset's filename, such as `"page.css"`
        # @return [String] the asset file's contents, read from beside this file
        def asset(name) = File.read(File.join(__dir__, name))
      end
    end
  end
end
