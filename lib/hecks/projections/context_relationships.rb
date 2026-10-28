require_relative "../naming"

module Hecks
  module Projections
    # The relationships between the contexts a registry holds, read off what each one already
    # declares: an `attaches` is a shared kernel, a policy with `across` is customer/supplier, a
    # hecksagon `translates` is the anti-corruption layer, and a bare `subscribe` is a listener.
    #
    # It reads a whole registry, not one bluebook, so it is a plain module and not a registered
    # `Projector` target. Each edge points from the context that depends to the one it depends on.
    module ContextRelationships
      Edge = Struct.new(:from, :to, :kind, :via) do
        # @return [Hash{Symbol => String, nil}] the edge as plain data
        def to_h = { from: from, to: to, kind: kind.to_s, via: via }
      end

      module_function

      # @param registry [Runtime::Registry] a registry whose bluebooks and hecksagons are loaded
      # @param owners [Hash{String => Array<String>}, nil] each aggregate name to the contexts that
      #   declare it across a whole corpus, for a translates whose source is in another registry
      # @return [Array<Hash>] every edge, ordered by dependent context, dependency and kind
      def call(registry:, owners: nil)
        edges(registry, owners).sort_by { |edge| [edge.from, edge.to, edge.kind.to_s, edge.via.to_s] }.map(&:to_h)
      end

      # @param registry [Runtime::Registry] a registry whose bluebooks and hecksagons are loaded
      # @return [String] one line per edge, `From --kind--> To (via)`
      def text(registry:)
        call(registry: registry).map do |edge|
          via = edge[:via] ? " (#{edge[:via]})" : ""
          "#{edge[:from]} --#{edge[:kind]}--> #{edge[:to]}#{via}"
        end.join("\n")
      end

      # @api private
      def edges(registry, owners)
        found = registry.hecksagons.values.flat_map do |hecksagon|
          attach_edges(hecksagon) + translate_edges(registry, hecksagon, owners) + subscription_edges(hecksagon)
        end
        found += registry.bluebooks.values.flat_map { |bluebook| across_edges(bluebook) }
        found.uniq.reject { |edge| redundant_subscription?(edge, found) }
      end

      # A context attaching its own vendored package shares nothing with another context.
      #
      # @api private
      def attach_edges(hecksagon)
        hecksagon.attachments.filter_map do |attachment|
          next if attachment.chapter_name.to_s == hecksagon.domain.to_s

          Edge.new(hecksagon.domain.to_s, attachment.chapter_name.to_s, :shared_kernel, nil)
        end
      end

      # @api private
      def across_edges(bluebook)
        bluebook.policies.select(&:target_domain).map do |policy|
          Edge.new(bluebook.name.to_s, policy.target_domain.to_s, :customer_supplier, policy.name.to_s)
        end
      end

      # @api private
      def translate_edges(registry, hecksagon, owners)
        policies = registry.bluebook(hecksagon.domain)&.policies || []
        hecksagon.translates.filter_map do |name|
          policy = policies.find { |candidate| candidate.name.to_s == name.to_s }
          source = policy && source_context(registry, policy, owners)
          Edge.new(hecksagon.domain.to_s, source, :acl, name.to_s) if source
        end
      end

      # A `translates` names the foreign event by its aggregate (`on Thing::ThingFired`), so the
      # context is whichever loaded bluebook declares that aggregate: one in this registry first,
      # then the corpus's single owner, and the aggregate's own name when neither is known.
      #
      # @api private
      def source_context(registry, policy, owners)
        aggregate = Naming.qualifier(policy.on_event)
        return unless aggregate

        local = declaring_bluebook(registry, aggregate, policy.on_event)
        (local&.name || sole_owner(owners, aggregate) || aggregate).to_s
      end

      # Two bluebooks may name an aggregate alike (Deploy's `Tenant` request and Tenancy's `Tenant`
      # fact), so of those declaring it the one that emits the event is the source: from a command,
      # or from a port operation that answers or refuses with it.
      #
      # @api private
      def declaring_bluebook(registry, aggregate, event)
        declaring = registry.bluebooks.values.select { |bluebook| bluebook.aggregate(aggregate) }
        declaring.find { |bluebook| emits?(bluebook, event) } || declaring.first
      end

      # @api private
      def emits?(bluebook, event)
        emitted = Bluebook::ModelCheck.emitted_events(bluebook).map { |name| Naming.last_segment(name) }
        emitted.include?(Naming.last_segment(event))
      end

      # @api private
      def sole_owner(owners, aggregate)
        found = Array(owners && owners[aggregate])
        found.first if found.size == 1
      end

      # @api private
      def subscription_edges(hecksagon)
        hecksagon.subscriptions.filter_map do |subscribed|
          context = Naming.qualifier(subscribed)
          Edge.new(hecksagon.domain.to_s, context, :subscription, subscribed) if context
        end
      end

      # A subscription that a stronger edge to the same context already explains adds nothing.
      #
      # @api private
      def redundant_subscription?(edge, found)
        edge.kind == :subscription &&
          found.any? { |other| other.from == edge.from && other.to == edge.to && other.kind != :subscription }
      end
    end
  end
end
