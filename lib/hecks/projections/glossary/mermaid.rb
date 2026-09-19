require_relative "../../naming"

module Hecks
  module Projections
    module Glossary
      # The three pictures the glossary draws, each kept to the handful of
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

        # Draws the whole chapter's aggregates and which points at which.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to draw
        # @return [String] a Mermaid `flowchart LR` source
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

        # Draws one aggregate, its entities, and its neighbours.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate to focus on
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to find
        #   neighbouring aggregates in
        # @return [String] a Mermaid `flowchart LR` source
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

        # Draws the states a holder can be in and what moves it between them.
        #
        # @param holder [Bluebook::Aggregate, Bluebook::Entity] the holder whose
        #   lifecycle to draw
        # @return [String] a Mermaid `stateDiagram-v2` source
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

        # Names a holder's own reference attributes.
        #
        # @param holder [Bluebook::Aggregate, Bluebook::Entity] the holder to
        #   read reference attributes from
        # @return [Array<Bluebook::Attribute>] `holder`'s own reference attributes
        def references(holder) = holder.attributes.select(&:reference?)

        # An entity is held as `list_of(LedgerEntry)` — the attribute
        # whose element type names one of the aggregate's own entities.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate to read entity
        #   attributes from
        # @return [Array<Bluebook::Attribute>] attributes whose element type is one
        #   of `aggregate`'s own entities
        def entities(aggregate)
          names = aggregate.entities.map(&:hecks_name)
          aggregate.attributes.select { |attribute| !attribute.reference? && names.include?(attribute.type.to_s) }
        end

        # Finds every other aggregate that references `aggregate`.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate to find pointers to
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to search other
        #   aggregates in
        # @return [Array<Array(Bluebook::Aggregate, Bluebook::Attribute)>] every other
        #   aggregate's own reference attribute that targets `aggregate`, paired
        #   with its holder
        def pointing_at(aggregate, bluebook)
          bluebook.aggregates.reject { |other| other.equal?(aggregate) }.flat_map do |other|
            references(other).select { |attribute| attribute.type.target_name == aggregate.hecks_name }
                             .map { |attribute| [other, attribute] }
          end
        end

        # ── the drawing ──────────────────────────────────────────────────

        # A node id the page source can carry without an identifier in
        # it — `n_atm_card`, never `n_ATMCard`.
        #
        # @param name [String, Symbol] the construct name to derive an id from
        # @return [String] a Mermaid-safe node id, such as `"n_atm_card"`
        def id(name) = "n_#{Naming.snake(name).gsub(/[^a-z0-9_]/, '_')}"

        # Renders one Mermaid node declaration.
        #
        # @param name [String, Symbol] the node's construct name
        # @param focus [Boolean] whether to mark this node with the `focus` CSS class
        # @return [String] a Mermaid node declaration line
        def node(name, focus: false)
          line = "    #{id(name)}[\"#{Naming.words(name)}\"]"
          focus ? "#{line}:::focus" : line
        end

        # Renders one Mermaid edge declaration.
        #
        # @param from [String, Symbol] the source node's construct name
        # @param attribute [Bluebook::Attribute] the attribute the edge is labelled after
        # @param to [String, Symbol] the target node's construct name
        # @return [String] a Mermaid edge declaration line, labelled with the
        #   attribute's spoken name
        def edge(from, attribute, to)
          "    #{id(from)} -->|\"#{Naming.words(attribute.name).downcase}\"| #{id(to)}"
        end
      end
    end
  end
end
