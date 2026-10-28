module Hecks
  module Bluebook
    module ModelCheck
      # The checks that hold a system's wiring to its declared context map (ADR 0135). The wiring
      # is `Projections::ContextRelationships`' edges, each pointing from the context that depends
      # to the one it depends on; the map's relationships run from upstream to downstream.
      module ContextMapChecks
        # The declared kinds each derived edge kind may implement. An attach and a subscription are
        # `conformist` unless the map says another kind for the pair; `shared_kernel` is declared,
        # never derived, since the wiring cannot tell a co-owned model from one taken as given.
        IMPLEMENTS = {
          "customer_supplier" => %i[customer_supplier],
          "acl"               => %i[anticorruption_layer],
          "shared_kernel"     => %i[conformist shared_kernel open_host],
          "subscription"      => %i[conformist customer_supplier open_host]
        }.freeze

        # Kinds with no direction: either context may be the one that depends.
        MUTUAL = %i[shared_kernel partnership].freeze

        # What separates a context or aggregate from an event's own name: `Billing.InvoicePaid`.
        QUALIFIER = /[.:]+/

        # @param map [Bluebook::ContextMap, nil] the declared map; nothing is checked without one
        # @param edges [Array<Hash>] `Projections::ContextRelationships.call`, for every registry
        # @return [Array<Finding>] what the wiring does that the map does not allow, and what the
        #   map declares that the wiring never uses
        def context_map_findings(map, edges)
          return [] unless map

          [*edges.flat_map { |edge| coupling_findings(map, edge) }, *unused_relationship_findings(map, edges)]
        end

        # @return [Array<Finding>] the findings for one derived edge
        def coupling_findings(map, edge)
          consumer = edge[:from]
          supplier = edge[:to]
          return [separate_ways_finding(edge)] if map.separate?(consumer, supplier)

          declared = map.relationships_between(consumer, supplier)
          return [undeclared_finding(edge, "no relationship is declared")] if declared.empty?

          aligned = declared.select { |relationship| runs_from?(relationship, supplier, consumer) }
          return [undeclared_finding(edge, reversed_note(declared))] if aligned.empty?

          kind_findings(edge, aligned)
        end

        # @return [Array<Finding>] the kind and published-language findings for an aligned edge
        def kind_findings(edge, aligned)
          if edge[:kind] == "acl" && aligned.any? { |relationship| relationship.kind == :conformist }
            return [conformist_translates_finding(edge)]
          end

          match = aligned.find { |relationship| IMPLEMENTS.fetch(edge[:kind], []).include?(relationship.kind) }
          return [kind_mismatch_finding(edge, aligned)] unless match

          unpublished_findings(edge, match)
        end

        # A subscription names the supplier event it depends on, so it can be held to the
        # relationship's published list. Other edges name a policy, which has no event to check.
        def unpublished_findings(edge, relationship)
          return [] unless edge[:kind] == "subscription" && relationship.published.to_a.any?
          return [] if published?(relationship, edge[:via])

          [Finding.new(kind: :unpublished_dependency, severity: :error, subject: edge_subject(edge),
                       message: "#{edge[:from]} reacts to #{edge[:via]}, which #{relationship.upstream} " \
                                "does not publish to it (published: #{relationship.published.join(", ")})")]
        end

        # @return [Boolean] whether the event is in the relationship's published list, by name
        def published?(relationship, event)
          relationship.published.map { |name| event_tail(name) }.include?(event_tail(event))
        end

        # @return [String] the event's own name, without its context or aggregate qualifier
        def event_tail(name)
          parts = name.to_s.split(QUALIFIER)
          parts.last.to_s
        end

        # @return [Boolean] whether the relationship has the supplier upstream and the consumer
        #   downstream, or is a kind with no direction
        def runs_from?(relationship, supplier, consumer)
          MUTUAL.include?(relationship.kind) ||
            (relationship.upstream == supplier && relationship.downstream == consumer)
        end

        # @return [Array<Finding>] one warning per declared relationship the wiring never uses
        def unused_relationship_findings(map, edges)
          map.relationships.filter_map do |relationship|
            next if edges.any? { |edge| edge_uses?(edge, relationship) }

            Finding.new(kind: :unused_relationship, severity: :warning,
                        subject: "#{relationship.downstream} <- #{relationship.upstream}",
                        message: "the map declares #{relationship.kind} here, but no wiring couples " \
                                 "these contexts")
          end
        end

        # @return [Boolean] whether the derived edge runs between the relationship's contexts
        def edge_uses?(edge, relationship)
          return edge_between?(edge, relationship) if MUTUAL.include?(relationship.kind)

          edge[:from] == relationship.downstream && edge[:to] == relationship.upstream
        end

        def edge_between?(edge, relationship) = [edge[:from], edge[:to]].sort == relationship.pair

        def edge_subject(edge) = "#{edge[:from]} -> #{edge[:to]}"

        def reversed_note(declared)
          first = declared.first
          "the map declares #{first.upstream} as upstream of #{first.downstream}, the other way round"
        end

        def undeclared_finding(edge, why)
          Finding.new(kind: :undeclared_coupling, severity: :error, subject: edge_subject(edge),
                      message: "#{edge[:kind]} couples these contexts (#{edge[:via] || "attach"}), " \
                               "and #{why}")
        end

        def kind_mismatch_finding(edge, aligned)
          Finding.new(kind: :relationship_kind_mismatch, severity: :error, subject: edge_subject(edge),
                      message: "the wiring is a #{edge[:kind]}, but the map declares " \
                               "#{aligned.map(&:kind).join(", ")}")
        end

        def separate_ways_finding(edge)
          Finding.new(kind: :separate_ways_violated, severity: :error, subject: edge_subject(edge),
                      message: "the map declares these contexts separate ways, but #{edge[:kind]} couples them")
        end

        def conformist_translates_finding(edge)
          Finding.new(kind: :conformist_translates, severity: :warning, subject: edge_subject(edge),
                      message: "the map declares #{edge[:from]} a conformist of #{edge[:to]}, " \
                               "yet it translates (#{edge[:via]}) — declare anticorruption_layer if so")
        end
      end
    end
  end
end
