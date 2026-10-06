module Hecks
  module Projections
    module Glossary
      module Html
        # Groups parsed blocks into the page's sections and renders each section's terms.
        module Sections
          module_function

          # GitHub's slugs for these headings, so links the Markdown carries land here too.
          # Keyed by identity: a Struct compares by members, so two "### Open" headings in
          # different sections would collide and `#open` would have nothing to land on.
          def heading_slugs(blocks)
            take  = Slugs.slug_taker
            slugs = {}.compare_by_identity
            blocks.select { |block| block.type == :heading }.each { |block| slugs[block] = take.call(block.text) }
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

          # Each `###` opens an article running to the next. A bold-only paragraph
          # captions whatever figure or list follows it.
          def section_html(section, slugs)
            heading = section[:heading]
            state = { parts: [%(<section id="#{slugs[heading]}">), "<h2>#{Html.inline(heading.text)}</h2>"],
                      caption: nil, in_terms: false }
            section[:blocks].drop(1).each { |block| section_block(block, state, slugs) }
            state[:parts] << "</article></div>" if state[:in_terms]
            state[:parts] << "</section>"
            state[:parts].join("\n")
          end

          # Renders one block into `state[:parts]`, mutating `state`.
          def section_block(block, state, slugs)
            case block.type
            when :heading then open_term(block, state, slugs)
            when :mermaid then state[:parts] << Html.figure(block, state.delete(:caption))
            when :list then list(block, state)
            when :quote then state[:parts] << "<p class=\"about\">#{Html.inline(block.text)}</p>"
            when :paragraph then paragraph(block.text, state)
            end
          end

          def open_term(block, state, slugs)
            parts = state[:parts]
            parts << (state[:in_terms] ? "</article>" : "<div class=\"terms\">")
            parts << %(<article class="term" id="#{slugs[block]}">) << "<h3>#{Html.inline(block.text)}</h3>"
            state[:in_terms] = true
          end

          def list(block, state)
            caption = state.delete(:caption)
            state[:parts] << "<p class=\"caption\">#{Html.escape(caption)}</p>" if caption
            items = block.items.map { |item| "<li>#{Html.inline(item)}</li>" }.join
            state[:parts] << "<ul class=\"rules\">#{items}</ul>"
          end

          def paragraph(text, state)
            if text.match?(/\A\*\*[^*]+\*\*\z/)
              state[:caption] = text.delete("*")
            else
              klass = text.start_with?("Always true:") ? " class=\"rule\"" : ""
              state[:parts] << "<p#{klass}>#{Html.inline(text)}</p>"
            end
          end
        end
      end
    end
  end
end
