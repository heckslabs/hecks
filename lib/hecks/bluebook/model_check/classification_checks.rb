module Hecks
  module Bluebook
    module ModelCheck
      # The checks a bluebook's `core`, `supporting` or `generic` keys (ADR 0172): a generic
      # subdomain may not depend on the core, and a core context should translate what it takes
      # from another rather than conform to it. Classifications are read from each bluebook, never
      # restated in a context map.
      module ClassificationChecks
        # @param edges [Array<Hash>] `Projections::ContextRelationships.call`, from the context that
        #   depends to the one it depends on
        # @param classifications [Hash{String => String}] each context to its classification
        # @return [Array<Finding>] one error per generic context that depends on a core one
        def generic_depends_on_core_findings(edges, classifications)
          edges.select { |edge| generic_on_core?(edge, classifications) }.uniq { |edge| [edge[:from], edge[:to]] }.map do |edge|
            Finding.new(kind: :generic_depends_on_core, severity: :error, subject: "#{edge[:from]} -> #{edge[:to]}",
                        message: "#{edge[:from]} is generic but depends on #{edge[:to]}, which is core " \
                                 "(#{edge[:kind]}#{" via #{edge[:via]}" if edge[:via]}); a generic subdomain must be " \
                                 "replaceable, so invert the dependency or reclassify one of them")
          end
        end

        # @param map [Bluebook::ContextMap] the declared map
        # @param classifications [Hash{String => String}] each context to its classification
        # @return [Array<Finding>] one warning per declared conformist relationship whose downstream
        #   is core, unless the relationship acknowledges it. The conformist ADR 0155 implies for an
        #   `attaches` is not declared and is not read.
        def core_conforms_findings(map, classifications)
          map.relationships.filter_map do |relationship|
            next unless core_conformist?(relationship, classifications)

            Finding.new(kind: :core_conforms, severity: :warning,
                        subject: "#{relationship.downstream} <- #{relationship.upstream}",
                        message: "#{relationship.downstream} is core but conforms to #{relationship.upstream}; " \
                                 "the core model should translate what it receives (an anticorruption_layer)")
          end
        end

        private

        def generic_on_core?(edge, classifications)
          classifications[edge[:from].to_s] == "generic" && classifications[edge[:to].to_s] == "core"
        end

        def core_conformist?(relationship, classifications)
          relationship.kind == :conformist && !relationship.implied &&
            classifications[relationship.downstream.to_s] == "core" && !relationship.acknowledges?(:core_conforms)
        end
      end
    end
  end
end
