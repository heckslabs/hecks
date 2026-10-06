module Hecks
  module Projections
    module Glossary
      # Reproduces GitHub's heading slugs, computed in document order, so links land the
      # same whether GitHub renders the `.md` or `Html` renders the page.
      module Slugs
        module_function

        def github(text) = text.to_s.downcase.gsub(/[^\p{Word}\- ]/, "").tr(" ", "-")

        # Assigns every section's and entry's slug, in document order.
        def assign!(bluebook, sections)
          take = slug_taker
          take.call(Markdown.title(bluebook))
          sections.each do |section|
            section.slug = take.call(section.title)
            section.terms.each { |entry| entry.slug = take.call(entry.headword) }
          end
        end

        # A lambda that answers each text's slug, numbering the repeats.
        def slug_taker
          seen = Hash.new(0)
          lambda do |text|
            base = github(text)
            seen[base] += 1
            seen[base] == 1 ? base : "#{base}-#{seen[base] - 1}"
          end
        end
      end
    end
  end
end
