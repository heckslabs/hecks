module Hecks
  module Bluebook
    module ModelCheck
      # No two contexts may depend on each other. Every kind of edge is a dependency with a
      # direction: an `attaches` and a `subscribe` as much as an `across` policy or a `translates`,
      # since the context that attaches or listens cannot be understood without the other.
      #
      # A cycle is an error, whatever the context map says. A relationship that accepts one
      # (`accepted_findings: { context_cycle: "reason" }`) excuses nothing from {REFUSED_FROM}: the
      # error names the acceptance, and an acceptance whose cycle is gone is reported to be removed.
      module ContextCycles
        # The edge kinds that make one context depend on another: all of them.
        DEPENDENCY_KINDS = %w[customer_supplier acl shared_kernel subscription].freeze
        # The release from which an accepted cycle is refused like any other.
        REFUSED_FROM = "8.0.0".freeze

        # Cycles are reported across the whole corpus: no one bluebook's check sees both directions.
        #
        # @param edges [Array<Hash>] `Projections::ContextRelationships.call`, for every registry
        # @param accepted [Hash{Array(String, String) => String}] each pair of contexts a context
        #   map accepts a cycle between, sorted, with its reason
        # @return [Array<Finding>] an error for each group of contexts that reach each other, and a
        #   warning for each accepted pair the wiring does not cycle through
        def context_cycle_findings(edges, accepted: {})
          groups = cyclic_groups(dependency_graph(edges))
          settled = accepted.keys.reject { |pair| groups.any? { |group| (pair - group).empty? } }
          groups.map { |group| refused_cycle_finding(group, accepted.keys) } + settled.map { |pair| settled_finding(pair) }
        end

        # @return [Hash{String => Array<String>}] each context to the contexts it depends on
        def dependency_graph(edges)
          edges.select { |edge| DEPENDENCY_KINDS.include?(edge[:kind]) && edge[:from] != edge[:to] }
               .each_with_object(Hash.new { |graph, node| graph[node] = [] }) do |edge, graph|
            graph[edge[:from]] |= [edge[:to]]
          end
        end

        # @param group [Array<String>] contexts that reach each other, sorted
        # @param pairs [Array<Array(String, String)>] the pairs a context map accepts a cycle
        #   between
        # @return [Finding] the error for the group, naming any acceptance inside it
        def refused_cycle_finding(group, pairs)
          held = pairs.select { |pair| (pair - group).empty? }
          Finding.new(kind: :context_cycle, severity: :error, subject: group.join(" <-> "),
                      message: refused_message(group) + held.map { |pair| acceptance_note(pair) }.join)
        end

        def refused_message(names)
          "these contexts depend on each other: #{names.join(", ")} — a context is upstream of another or " \
            "downstream of it, never both; move the reactions to one side's hecksagon, or make them one context"
        end

        def acceptance_note(pair)
          "; the context map accepts the cycle between #{pair.join(" and ")} (accepted_findings: " \
            "{ context_cycle: ... }), which excuses no cycle from #{REFUSED_FROM}"
        end

        # @param maps [Array<Bluebook::ContextMap>] the context maps of every booted system
        # @return [Hash{Array(String, String) => String}] each pair a map accepts a cycle between,
        #   with the reason its relationship gives
        def accepted_cycles(maps)
          held = maps.flat_map(&:relationships).select { |relationship| relationship.acknowledges?(:context_cycle) }
          held.to_h { |relationship| [relationship.pair, relationship.acknowledged[:context_cycle]] }
        end

        # @param edges [Array<Hash>] `Projections::ContextRelationships.call`, for every registry
        # @param maps [Array<Bluebook::ContextMap>] the context maps of every booted system
        # @return [Array<Finding>] {#context_cycle_findings}, with the cycles those maps accept
        def corpus_cycle_findings(edges, maps) = context_cycle_findings(edges, accepted: accepted_cycles(maps))

        def settled_finding(pair)
          Finding.new(kind: :context_cycle_settled, severity: :warning, subject: pair.join(" <-> "),
                      message: "the context map accepts a cycle between #{pair.join(" and ")}, and the wiring " \
                               "has none — remove `context_cycle` from the relationship's accepted_findings, " \
                               "which excuses nothing from #{REFUSED_FROM}")
        end

        # Nodes that reach each other, grouped. A node with no way back is not in a cycle.
        def cyclic_groups(graph)
          reach = graph.keys.to_h { |node| [node, reachable_from(graph, node)] }
          groups = reach.keys.map do |node|
            ([node] + reach[node].select { |other| reach.fetch(other, []).include?(node) }).uniq.sort
          end
          groups.select { |group| group.size > 1 }.uniq
        end

        # @return [Array] every node reachable by following dependencies from `start`
        def reachable_from(graph, start)
          seen = []
          queue = graph.fetch(start, []).dup
          until queue.empty?
            node = queue.shift
            next if seen.include?(node)

            seen << node
            queue.concat(graph.fetch(node, []))
          end
          seen
        end
      end
    end
  end
end
