require_relative "../../naming"

module Hecks
  module Projections
    module Glossary
      # THE THREE PICTURES THE GLOSSARY DRAWS, each kept to the handful of
      # things that matter — Evans' "three to five objects central to the
      # issue at hand", never the whole model at once.
      #
      #   map        the aggregates and which points at which — one small
      #              graph at the top, for the reader who wants the shape
      #              of the domain before its words.
      #   context    one aggregate, its entities, and the neighbours it
      #              points at or is pointed at by. Value objects are
      #              words in the text ("Made up of …"), not boxes here —
      #              Account alone has eight, and eight boxes say less
      #              than one sentence.
      #   lifecycle  the states a thing can be in and what moves it.
      #
      # Every label is a person's spelling (`Naming.words`), and the
      # edges read from the same declared facts `Projections::Diagrams`
      # draws its own from (`reference?`, `type.target_name`, `name`,
      # `lifecycle.transitions`) — a different picture of the same
      # declaration, not a second declaration.
      module Mermaid
        module_function

        def map(bluebook)
          names = bluebook.aggregates.map(&:hecks_name)
          lines = ["flowchart LR"]
          names.each { |name| lines << node(name) }
          bluebook.aggregates.each do |aggregate|
            references(aggregate).each do |attribute|
              target = attribute.type.target_name
              lines << node(target) unless names.include?(target) || lines.include?(node(target))
              lines << edge(aggregate.hecks_name, attribute, target)
            end
          end
          lines.join("\n")
        end

        def context(aggregate, bluebook)
          focus = aggregate.hecks_name
          lines = ["flowchart LR", node(focus, focus: true)]
          entities(aggregate).each do |attribute|
            lines << node(attribute.type.to_s)
            lines << edge(focus, attribute, attribute.type.to_s)
          end
          references(aggregate).each do |attribute|
            lines << node(attribute.type.target_name)
            lines << edge(focus, attribute, attribute.type.target_name)
          end
          pointing_at(aggregate, bluebook).each do |holder, attribute|
            lines << node(holder.hecks_name)
            lines << edge(holder.hecks_name, attribute, focus)
          end
          lines << "    classDef focus stroke-width:3px"
          lines.uniq.join("\n")
        end

        def lifecycle(holder)
          lifecycle = holder.lifecycle
          lines = ["stateDiagram-v2"]
          states = ([lifecycle.default] + lifecycle.transitions.map { |_name, transition| transition.target }).uniq
          states.select { |state| state.to_s.include?("_") }.each do |state|
            lines << "    state \"#{state.to_s.tr('_', ' ')}\" as #{state}"
          end
          lines << "    [*] --> #{lifecycle.default}"
          lifecycle.transitions.each do |name, transition|
            Array(transition.from).each { |from| lines << "    #{from} --> #{transition.target}: #{Naming.words(name)}" }
          end
          lines.join("\n")
        end

        # ── the facts drawn ──────────────────────────────────────────────

        def references(holder) = holder.attributes.select(&:reference?)

        # An entity is held as `list_of(LedgerEntry)` — the attribute
        # whose element type names one of the aggregate's own entities.
        def entities(aggregate)
          names = aggregate.entities.map(&:hecks_name)
          aggregate.attributes.select { |attribute| !attribute.reference? && names.include?(attribute.type.to_s) }
        end

        def pointing_at(aggregate, bluebook)
          bluebook.aggregates.reject { |other| other.equal?(aggregate) }.flat_map do |other|
            references(other).select { |attribute| attribute.type.target_name == aggregate.hecks_name }
                             .map { |attribute| [other, attribute] }
          end
        end

        # ── the drawing ──────────────────────────────────────────────────

        # A node id the page source can carry without an identifier in
        # it — `n_atm_card`, never `n_ATMCard`.
        def id(name) = "n_#{Naming.snake(name).gsub(/[^a-z0-9_]/, '_')}"

        def node(name, focus: false)
          line = "    #{id(name)}[\"#{Naming.words(name)}\"]"
          focus ? "#{line}:::focus" : line
        end

        def edge(from, attribute, to)
          "    #{id(from)} -->|\"#{Naming.words(attribute.name).downcase}\"| #{id(to)}"
        end
      end
    end
  end
end
