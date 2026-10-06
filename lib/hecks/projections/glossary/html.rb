require_relative "../../forms/html"
require_relative "html/parser"
require_relative "html/sections"
require_relative "html/page"

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
          blocks = Parser.parse(markdown)
          slugs  = Sections.heading_slugs(blocks)
          title  = blocks.find { |block| block.type == :heading && block.level == 1 }&.text.to_s
          sections = Sections.split_sections(blocks)
          Page.page(title, sections, slugs)
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
