require_relative "context_map_checks"

module Hecks
  module Bluebook
    module ModelCheck
      # The checks over how contexts relate to each other: a `translates` has to listen to a context
      # this hecksagon acknowledges, and no two contexts may depend on each other in a cycle.
      module ContextChecks
        include ContextMapChecks

        # The edge kinds that couple two contexts at run time. A shared kernel merges in-process, so
        # two contexts attaching each other is a different question and is left out.
        COUPLING_KINDS = %w[customer_supplier acl].freeze

        # A `translates` reacts to a foreign event, so the context that owns that event has to be
        # attached or subscribed to, as an `across` policy's target does.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook whose policies are checked
        # @param hecksagon [Bluebook::Hecksagon, nil] the bluebook's own wiring
        # @param owners [Hash{String => Array<String>}, nil] each aggregate name to the contexts
        #   that declare it; nothing is checked without it
        # @return [Array<Finding>] one finding per translates whose source is not acknowledged
        def translates_source_findings(bluebook, hecksagon, owners)
          return [] unless hecksagon && owners

          translated = bluebook.policies.select { |policy| hecksagon.translates.include?(policy.name.to_s) }
          translated.filter_map { |policy| unacknowledged_source_finding(bluebook, policy, hecksagon, owners) }
        end

        # The aggregate name is not unique across contexts, so a source counts as acknowledged when
        # any context that declares it is.
        def unacknowledged_source_finding(bluebook, policy, hecksagon, owners)
          sources = Array(owners[Naming.qualifier(policy.on_event)]).map(&:to_s)
          return if sources.empty? || sources.include?(bluebook.name.to_s)
          return if sources.any? { |source| acknowledged_source?(hecksagon, source) }

          Finding.new(kind: :unacknowledged_source, severity: :error, subject: policy.name,
                      message: unacknowledged_source_message(policy, sources))
        end

        # @return [String] what is wrong and the two ways to acknowledge the source
        def unacknowledged_source_message(policy, sources)
          "translates #{policy.on_event.inspect}, which #{sources.join(" or ")} owns, but " \
            "nothing in this hecksagon acknowledges it — add attaches #{sources.first.inspect} " \
            "or subscribe \"#{sources.first}.SomeEvent\""
        end

        # @return [Boolean] whether the hecksagon attaches the context or subscribes to its events
        def acknowledged_source?(hecksagon, source)
          hecksagon.attaches?(source) || hecksagon.subscriptions.any? { |event| Naming.qualifier(event) == source }
        end

        # Cycles are reported across the whole corpus: no one bluebook's check sees both directions.
        #
        # @param edges [Array<Hash>] `Projections::ContextRelationships.call`, for every registry
        # @return [Array<Finding>] one warning per group of contexts that reach each other
        def context_cycle_findings(edges)
          cyclic_groups(coupling_graph(edges)).map do |group|
            Finding.new(kind: :context_cycle, severity: :warning, subject: group.join(" <-> "),
                        message: "these contexts depend on each other through across or translates: #{group.join(", ")}")
          end
        end

        # @return [Hash{String => Array<String>}] each context to the contexts it depends on
        def coupling_graph(edges)
          edges.select { |edge| COUPLING_KINDS.include?(edge[:kind]) }
               .each_with_object(Hash.new { |graph, node| graph[node] = [] }) do |edge, graph|
            graph[edge[:from]] << edge[:to]
          end
        end

        # Contexts that reach each other, grouped. A context with no way back is not in a cycle.
        def cyclic_groups(graph)
          reach = graph.keys.to_h { |node| [node, reachable_from(graph, node)] }
          groups = reach.keys.map do |node|
            ([node] + reach[node].select { |other| reach.fetch(other, []).include?(node) }).uniq.sort
          end
          groups.select { |group| group.size > 1 }.uniq
        end

        # @return [Array<String>] every context reachable by following dependencies from `start`
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
