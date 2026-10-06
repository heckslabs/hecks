require_relative "../../naming"

module Hecks
  module Projections
    module Glossary
      # The glossary's three diagrams: the map, one aggregate's context, and a lifecycle.
      # Value objects appear as words in the text, not as boxes, to keep diagrams small.
      module Mermaid
        module_function

        # Draws the whole chapter's aggregates and which points at which.
        #
        # @return [String] a Mermaid `flowchart LR` source
        def map(bluebook)
          names = bluebook.aggregates.map(&:hecks_name)
          lines = ["flowchart LR"] + names.map { |name| node(name) }
          bluebook.aggregates.each { |aggregate| add_references(lines, aggregate, names) }
          lines.join("\n")
        end

        # Adds a node for each reference target not yet drawn, and an edge for each reference.
        def add_references(lines, aggregate, names)
          references(aggregate).each do |attribute|
            target = attribute.type.target_name
            lines << node(target) unless names.include?(target) || lines.include?(node(target))
            lines << edge(aggregate.hecks_name, attribute, target)
          end
        end

        # Draws one aggregate, its entities, and its neighbours.
        #
        # @return [String] a Mermaid `flowchart LR` source
        def context(aggregate, bluebook)
          lines = ["flowchart LR", node(aggregate.hecks_name, focus: true)] + neighbours(aggregate, bluebook)
          (lines << "    classDef focus stroke-width:3px").uniq.join("\n")
        end

        # The nodes and edges for the aggregate's entities, what it references, and what
        # references it.
        def neighbours(aggregate, bluebook)
          focus = aggregate.hecks_name
          entities(aggregate).flat_map { |attribute| link(focus, attribute, attribute.type.to_s) } +
            references(aggregate).flat_map { |attribute| link(focus, attribute, attribute.type.target_name) } +
            incoming(aggregate, bluebook)
        end

        # A node for each holder that references `aggregate`, and its edge in.
        def incoming(aggregate, bluebook)
          pointing_at(aggregate, bluebook).flat_map do |holder, attribute|
            [node(holder.hecks_name), edge(holder.hecks_name, attribute, aggregate.hecks_name)]
          end
        end

        # A node for `to` and the edge from `from` to it.
        def link(from, attribute, to) = [node(to), edge(from, attribute, to)]

        # Draws the states a holder can be in and what moves it between them.
        #
        # @return [String] a Mermaid `stateDiagram-v2` source
        def lifecycle(holder)
          lifecycle = holder.lifecycle
          lines = ["stateDiagram-v2"] + state_labels(lifecycle) + ["    [*] --> #{lifecycle.default}"]
          (lines + transition_lines(lifecycle)).join("\n")
        end

        # A readable label for each state whose name has an underscore.
        def state_labels(lifecycle)
          states = ([lifecycle.default] + lifecycle.transitions.map { |_name, transition| transition.target }).uniq
          states.select { |state| state.to_s.include?("_") }.map do |state|
            "    state \"#{state.to_s.tr("_", " ")}\" as #{state}"
          end
        end

        def transition_lines(lifecycle)
          lifecycle.transitions.flat_map do |name, transition|
            Array(transition.from).map { |from| "    #{from} --> #{transition.target}: #{Naming.words(name)}" }
          end
        end

        def references(holder) = holder.attributes.select(&:reference?)

        # An entity is held as `list_of(LedgerEntry)`: an attribute whose element type
        # names one of the aggregate's own entities.
        def entities(aggregate)
          names = aggregate.entities.map(&:hecks_name)
          aggregate.attributes.select { |attribute| !attribute.reference? && names.include?(attribute.type.to_s) }
        end

        # Finds every other aggregate's reference attribute that targets `aggregate`,
        # as `[holder, attribute]` pairs.
        def pointing_at(aggregate, bluebook)
          bluebook.aggregates.reject { |other| other.equal?(aggregate) }.flat_map do |other|
            references(other).select { |attribute| attribute.type.target_name == aggregate.hecks_name }
                             .map { |attribute| [other, attribute] }
          end
        end

        # A node id that carries no identifier: `n_atm_card`, never `n_ATMCard`.
        def id(name) = "n_#{Naming.snake(name).gsub(/[^a-z0-9_]/, "_")}"

        # Renders one Mermaid node declaration, marked `focus` when asked.
        def node(name, focus: false)
          line = "    #{id(name)}[\"#{Naming.words(name)}\"]"
          focus ? "#{line}:::focus" : line
        end

        # Renders one Mermaid edge, labelled with the attribute's spoken name.
        def edge(from, attribute, to)
          "    #{id(from)} -->|\"#{Naming.words(attribute.name).downcase}\"| #{id(to)}"
        end
      end
    end
  end
end
