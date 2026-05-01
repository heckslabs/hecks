# Hecks::ValidationRules::Structure::AntiCorruptionTranslation
#
# Warns when a reactive policy listens for an event from an upstream context
# that has an +:anti_corruption+ relationship but the policy lacks a
# +translate+ block.
#
# The anti-corruption pattern requires translating upstream vocabulary into
# the downstream context's ubiquitous language. A policy without a translate
# block is directly consuming the upstream's event shape, violating the
# pattern boundary.
#
# Checks both aggregate-level and domain-level policies against the
# context_map declared in the hecksagon.
#
#   rule = AntiCorruptionTranslation.new(domain)
#   rule.warnings  # => ["Policy SyncOrder listens for OrderPlaced from ..."]
#
module Hecks
  module ValidationRules
    module Structure
      class AntiCorruptionTranslation < BaseRule
        # Returns no errors. This rule only produces warnings.
        #
        # @return [Array] always empty
        def errors
          []
        end

        # Returns warnings for policies that consume upstream anti-corruption
        # events without a translate block.
        #
        # @return [Array<String>] warning messages
        def warnings
          return [] unless context_map_available?

          result = []
          all_local_events = @domain.aggregates.flat_map { |a| a.events.map(&:name) }

          each_reactive_policy do |policy, owner_label|
            next if all_local_events.include?(policy.event_name)
            next if policy.translate

            upstream = anti_corruption_upstream_for(policy.event_name)
            next unless upstream

            result << "Policy #{policy.name} (#{owner_label}) listens for " \
                      "#{policy.event_name} from upstream #{upstream} which has an " \
                      ":anti_corruption relationship. Add a translate block to " \
                      "convert upstream vocabulary into #{@domain.name}'s language."
          end
          result
        end

        private

        def context_map_available?
          @domain.respond_to?(:context_map_relationships) &&
            @domain.context_map_relationships.is_a?(Array) &&
            !@domain.context_map_relationships.empty?
        end

        def context_map
          @domain.context_map_relationships || []
        end

        # Yield each reactive policy with a label describing its owner.
        def each_reactive_policy
          @domain.aggregates.each do |agg|
            agg.policies.each do |policy|
              next unless policy.reactive?
              yield policy, "in #{agg.name}"
            end
          end

          @domain.policies.each do |policy|
            next unless policy.reactive?
            yield policy, "domain-level"
          end
        end

        # Find the upstream context name if this domain is the downstream
        # in an :anti_corruption relationship with that upstream.
        # Returns nil if no such relationship exists.
        def anti_corruption_upstream_for(_event_name)
          context_map.each do |entry|
            next unless entry[:type] == :upstream_downstream
            next unless entry[:relationship] == :anti_corruption
            next unless entry[:target] == @domain.name

            return entry[:source]
          end
          nil
        end
      end
      Hecks.register_validation_rule(AntiCorruptionTranslation)
    end
  end
end
