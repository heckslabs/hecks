module Hecks
  module Projections
    module Glossary
      module Html
        # Groups parsed blocks into the page's sections and renders each section's terms.
        module Sections
          # Paragraph openings that mark a rule, and the class that sets each apart on the page.
          LEADS = {
            "Always true:" => "rule", "Allowed only when:" => "rule", "Afterwards, always:" => "rule"
          }.freeze

          # A paragraph that is all bold, `**Like this**`: the caption of the figure below it.
          CAPTION = /\A\*\*[^*]+\*\*\z/

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

          # Each `###` opens a group of terms and each `####` a term running to the next. A
          # bold-only paragraph captions whatever figure or list follows it.
          def section_html(section, slugs)
            heading = section[:heading]
            state = { parts: [%(<section id="#{slugs[heading]}">), "<h2>#{Html.inline(heading.text)}</h2>"],
                      caption: nil, open: nil }
            section[:blocks].drop(1).each { |block| section_block(block, state, slugs) }
            close(state, nil)
            state[:parts] << "</section>"
            state[:parts].join("\n")
          end

          # Renders one block into `state[:parts]`, mutating `state`.
          def section_block(block, state, slugs)
            case block.type
            when :heading then block.level == 3 ? open_group(block, state, slugs) : open_term(block, state, slugs)
            when :mermaid then state[:parts] << Html.figure(block, state.delete(:caption))
            when :list then list(block, state)
            when :quote then state[:parts] << "<p class=\"about\">#{Html.inline(block.text)}</p>"
            when :paragraph then paragraph(block.text, state)
            end
          end

          def open_group(block, state, slugs)
            close(state, nil)
            state[:parts] << %(<h3 class="group" id="#{slugs[block]}">#{Html.inline(block.text)}</h3>)
          end

          def open_term(block, state, slugs)
            close(state, :terms)
            state[:parts] << "<div class=\"terms\">" unless state[:open]
            state[:parts] << %(<article class="term" id="#{slugs[block]}">) << "<h4>#{Html.inline(block.text)}</h4>"
            state[:open] = :article
          end

          # Closes the open article, and the terms around it unless `keep` is `:terms`.
          def close(state, keep)
            state[:parts] << "</article>" if state[:open] == :article
            state[:open] = :terms if state[:open]
            return if keep == :terms

            state[:parts] << "</div>" if state[:open]
            state[:open] = nil
          end

          def list(block, state)
            caption = state.delete(:caption)
            state[:parts] << "<p class=\"caption\">#{Html.escape(caption)}</p>" if caption
            items = block.items.map { |item| "<li>#{Html.inline(item)}</li>" }.join
            state[:parts] << "<ul class=\"rules\">#{items}</ul>"
          end

          def paragraph(text, state)
            if text.match?(CAPTION)
              state[:caption] = text.delete("*")
            else
              klass = LEADS.find { |lead, _class| text.start_with?(lead) }&.last
              state[:parts] << "<p#{%( class="#{klass}") if klass}>#{Html.inline(text)}</p>"
            end
          end
        end
      end
    end
  end
end
