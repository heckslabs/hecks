module Hecks
  module Bluebook
    module ModelCheck
      # No two contexts may depend on each other. Every kind of edge is a dependency with a
      # direction: an `attaches` and a `subscribe` as much as an `across` policy or a `translates`,
      # since the context that attaches or listens cannot be understood without the other.
      #
      # A cycle that stood before the rule is accepted on its relationship in the context map
      # (`accepted_findings: { context_cycle: "reason" }`) and reported as deprecated; one that is
      # not accepted is an error. An accepted pair is read as one context while it stands, so a
      # longer ring through it is still refused.
      module ContextCycles
        # The edge kinds that make one context depend on another: all of them.
        DEPENDENCY_KINDS = %w[customer_supplier acl shared_kernel subscription].freeze
        # The release from which an accepted cycle is refused too.
        REFUSED_FROM = "8.0.0".freeze

        # Cycles are reported across the whole corpus: no one bluebook's check sees both directions.
        #
        # @param edges [Array<Hash>] `Projections::ContextRelationships.call`, for every registry
        # @param accepted [Hash{Array(String, String) => String}] each pair of contexts a context
        #   map accepts a cycle between, sorted, with its reason
        # @return [Array<Finding>] an error for each group of contexts that reach each other, and
        #   a warning for each accepted pair: deprecated while it stands, stale once it is gone
        def context_cycle_findings(edges, accepted: {})
          graph = dependency_graph(edges)
          refused_cycle_findings(graph, accepted.keys) + accepted.map { |pair, reason| accepted_finding(graph, pair, reason) }
        end

        # @return [Hash{String => Array<String>}] each context to the contexts it depends on
        def dependency_graph(edges)
          edges.select { |edge| DEPENDENCY_KINDS.include?(edge[:kind]) && edge[:from] != edge[:to] }
               .each_with_object(Hash.new { |graph, node| graph[node] = [] }) do |edge, graph|
            graph[edge[:from]] |= [edge[:to]]
          end
        end

        # @return [Array<Finding>] an error for each cycle the accepted pairs do not explain
        def refused_cycle_findings(graph, pairs)
          cyclic_groups(merged(graph, pairs)).map do |group|
            names = group.flatten.sort
            Finding.new(kind: :context_cycle, severity: :error, subject: names.join(" <-> "), message: refused_message(names))
          end
        end

        def refused_message(names)
          "these contexts depend on each other: #{names.join(", ")} — a context is upstream of another or " \
            "downstream of it, never both; move the reactions to one side's hecksagon, or make them one context"
        end

        # The graph with each accepted pair drawn as one node, and no edge inside a node.
        def merged(graph, pairs)
          node = nodes_of(graph, pairs)
          graph.each_with_object(Hash.new { |held, key| held[key] = [] }) do |(from, targets), held|
            targets.each { |to| held[node[from]] |= [node[to]] unless node[from] == node[to] }
          end
        end

        # @return [Hash{String => Array<String>}] each context to the accepted group it stands in
        def nodes_of(graph, pairs)
          names = (graph.keys + graph.values.flatten + pairs.flatten).uniq
          pairs.each_with_object(names.to_h { |name| [name, [name]] }) { |pair, node| join(node, pair) }
        end

        # Puts the two contexts of a pair, and whatever each already stands with, in one group.
        def join(node, pair)
          joined = pair.flat_map { |name| node[name] }.uniq.sort
          joined.each { |name| node[name] = joined }
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

        def accepted_finding(graph, pair, reason)
          left, right = pair
          standing = reachable_from(graph, left).include?(right) && reachable_from(graph, right).include?(left)
          Finding.new(kind: standing ? :context_cycle : :context_cycle_settled, severity: :warning,
                      subject: pair.join(" <-> "), message: standing ? deprecated_message(pair, reason) : settled_message(pair))
        end

        def deprecated_message(pair, reason)
          "#{pair.join(" and ")} depend on each other, accepted in the context map (#{reason}); an accepted " \
            "context cycle is deprecated and refused from #{REFUSED_FROM}"
        end

        def settled_message(pair)
          "the context map accepts a cycle between #{pair.join(" and ")}, and the wiring no longer has one — " \
            "remove `context_cycle` from the relationship's accepted_findings"
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
