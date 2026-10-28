require_relative "../bluebook/model_check"

module Hecks
  module Projections
    # A context map drawn as a Mermaid flowchart in the standard notation (ADR 0135): each edge
    # runs from the upstream context to the downstream one, with the end marks of Evans's context
    # map. The declared relationships and the wiring's derived edges are drawn together: a coupling
    # the map does not declare is dashed and red, a relationship the wiring never uses is grey, and
    # an attach the map leaves implied (ADR 0155) is dotted and labelled `attaches`.
    module ContextMapDiagram
      # The edge label each declared kind is drawn with.
      LABELS = {
        customer_supplier:    "U/S → D/C",
        conformist:           "U → D/CF",
        anticorruption_layer: "U → D/ACL",
        open_host:            "U/OHS+PL → D",
        shared_kernel:        "SK",
        partnership:          "P"
      }.freeze

      # What a Mermaid node id cannot hold, so a context named with spaces still draws.
      NOT_AN_IDENTIFIER = /\W/

      UNDECLARED_STYLE = "stroke:#c00,stroke-width:2px,stroke-dasharray:5".freeze
      UNUSED_STYLE     = "stroke:#999,color:#999".freeze
      IMPLIED_STYLE    = "stroke:#678,stroke-dasharray:2".freeze

      module_function

      # @param map [Bluebook::ContextMap, nil] the declared map, or none to draw the wiring alone
      # @param edges [Array<Hash>] `Projections::ContextRelationships.call`
      # @return [String] the Mermaid source
      def call(map:, edges:)
        map &&= map.implying(edges)
        links = declared_links(map, edges) + undeclared_links(map, edges)
        lines = ["flowchart LR", *node_lines(map, edges), *links.map { |link| link[:line] }]
        lines.concat(style_lines(links))
        lines.concat(separate_ways_lines(map))
        lines.join("\n")
      end

      # The diagram, followed by what holding the wiring to the map finds, one Mermaid comment a
      # line.
      # A system with no declared map is drawn from its wiring alone and says so.
      #
      # @param map [Bluebook::ContextMap, nil] the declared map
      # @param edges [Array<Hash>] `Projections::ContextRelationships.call`
      # @return [String] the Mermaid source and its findings
      def report(map:, edges:)
        notes = map ? findings_lines(map, edges) : ["  %% no context map is declared; the wiring is drawn alone"]
        [call(map: map, edges: edges), *notes].join("\n")
      end

      # @api private
      def findings_lines(map, edges)
        found = Bluebook::ModelCheck.context_map_findings(map, edges)
        return ["  %% the wiring matches the declared map"] if found.empty?

        found.map { |finding| "  %% #{finding.severity} #{finding.kind} #{finding.subject}: #{finding.message}" }
      end

      # @api private
      def declared_links(map, edges)
        return [] unless map

        map.relationships.map do |relationship|
          used = edges.any? { |edge| Bluebook::ModelCheck.edge_uses?(edge, relationship) }
          { line: declared_line(relationship), style: link_style(relationship, used) }
        end
      end

      # @api private
      def link_style(relationship, used)
        return IMPLIED_STYLE if relationship.implied

        used ? nil : UNUSED_STYLE
      end

      # @api private
      def undeclared_links(map, edges)
        edges.reject { |edge| covered?(map, edge) }.map do |edge|
          { line: "  #{id(edge[:to])} -. \"#{edge[:kind]}\" .-> #{id(edge[:from])}", style: UNDECLARED_STYLE }
        end
      end

      # @api private
      def covered?(map, edge)
        map&.relationships&.any? { |relationship| Bluebook::ModelCheck.edge_uses?(edge, relationship) }
      end

      # @api private
      def declared_line(relationship)
        from = id(relationship.upstream)
        to   = id(relationship.downstream)
        label = LABELS.fetch(relationship.kind)
        return "  #{from} -. \"attaches · #{label}\" .-> #{to}" if relationship.implied

        case relationship.kind
        when :shared_kernel then "  #{from} -- \"#{label}\" --- #{to}"
        when :partnership   then "  #{from} <-- \"#{label}\" --> #{to}"
        else "  #{from} -- \"#{label}\" --> #{to}"
        end
      end

      # @api private
      def node_lines(map, edges)
        teams = (map&.contexts || []).to_h { |context| [context.name.to_s, context.team] }
        node_names(map, edges).map { |name| "  #{id(name)}[\"#{[name, teams[name]].compact.join("<br/>")}\"]" }
      end

      # @api private
      def node_names(map, edges)
        declared = map ? map.context_names : []
        (declared + edges.flat_map { |edge| [edge[:from], edge[:to]] }).uniq
      end

      # Mermaid styles an edge by its position among the links.
      #
      # @api private
      def style_lines(links)
        links.each_with_index.filter_map do |link, index|
          "  linkStyle #{index} #{link[:style]}" if link[:style]
        end
      end

      # @api private
      def separate_ways_lines(map)
        (map&.separate_ways || []).map { |left, right| "  %% separate ways: #{left} | #{right}" }
      end

      # @api private
      def id(name) = name.to_s.gsub(NOT_AN_IDENTIFIER, "_")
    end
  end
end
