module Hecks
  module Projections
    module Glossary
      # The groups an aggregate's terms are listed under, so a reader meets what can be done
      # with a thing before the lists and the parts it is made of. Each group is a `###`
      # heading in the Markdown, so GitHub and the page give the terms the same slugs.
      module Groups
        # Kind => the group's heading, in the order the groups are shown.
        LABELS = {
          command: "Actions", event: "What it records", policy: "What happens on its own",
          saga: "What happens on its own", query: "Lists", entity: "What it is made of",
          value_object: "What it is made of"
        }.freeze

        ORDER = LABELS.values.uniq.freeze

        module_function

        # @param entry [Glossary::Entry] a term
        # @return [Integer] where its group sits; terms outside every group come first
        def rank(entry) = ORDER.index(LABELS[entry.kind]) || -1

        # A section's terms with a group heading before the first term of each group. Only an
        # aggregate's section is grouped.
        #
        # @param section [Glossary::Section] the section, its terms already sorted
        # @return [Array<Array(Symbol, Object)>] `[:group, label]` and `[:term, entry]` pairs
        def walk(section)
          return section.terms.map { |entry| [:term, entry] } unless section.aggregate

          last = nil
          section.terms.flat_map do |entry|
            label = LABELS[entry.kind]
            heading = label == last ? [] : [[:group, label]]
            last = label
            heading + [[:term, entry]]
          end
        end
      end
    end
  end
end
