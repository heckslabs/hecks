# Hecks::ValidationRules::References::CrossContextReferences
#
# Warns when an aggregate has a cross-domain +reference_to+ (qualified with
# a domain prefix like "Billing::Invoice") but no context_map entry declares
# the relationship between the two bounded contexts.
#
# This rule is advisory-only during multi-domain boot. When the hecksagon
# declares a context_map, every qualified reference should have a matching
# upstream/downstream or shared_kernel entry. Missing entries suggest an
# undeclared coupling.
#
# Single-domain compilations skip this check (no cross-domain refs to validate).
#
#   rule = CrossContextReferences.new(domain)
#   rule.warnings  # => ["Pizza references Billing::Invoice but no context_map ..."]
#
module Hecks
  module ValidationRules
    module References
      class CrossContextReferences < BaseRule
        # Returns no errors. This rule only produces warnings.
        #
        # @return [Array] always empty
        def errors
          []
        end

        # Returns warnings for cross-domain references that lack a context_map
        # relationship declaration.
        #
        # @return [Array<String>] warning messages
        def warnings
          return [] unless context_map_available?

          result = []
          @domain.aggregates.each do |agg|
            (agg.references || []).each do |ref|
              next unless ref.domain
              next if relationship_declared?(ref.domain)

              result << "#{agg.name} references #{ref.domain}::#{ref.type} " \
                        "but no context_map entry declares the relationship " \
                        "between #{@domain.name} and #{ref.domain}. " \
                        "Add an upstream/downstream or shared_kernel entry."
            end
          end
          result
        end

        private

        def context_map_available?
          @domain.respond_to?(:context_map_relationships) &&
            @domain.context_map_relationships.is_a?(Array)
        end

        def context_map
          @domain.context_map_relationships || []
        end

        # Check if any context_map entry covers the relationship between
        # this domain and the target domain.
        def relationship_declared?(target_domain)
          context_map.any? do |entry|
            case entry[:type]
            when :upstream_downstream
              covers_pair?(entry[:source], entry[:target], target_domain)
            when :shared_kernel
              (entry[:contexts] || []).include?(@domain.name) &&
                (entry[:contexts] || []).include?(target_domain)
            else
              false
            end
          end
        end

        def covers_pair?(source, target, other_domain)
          (source == @domain.name && target == other_domain) ||
            (source == other_domain && target == @domain.name)
        end
      end
      Hecks.register_validation_rule(CrossContextReferences)
    end
  end
end
