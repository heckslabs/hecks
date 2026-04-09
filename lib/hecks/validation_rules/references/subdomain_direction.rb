# Hecks::ValidationRules::References::SubdomainDirection
#
# Enforces that core subdomains never depend on generic subdomains.
# Dependency direction should flow from generic → supporting → core,
# not the reverse. Checks reference_to across domains during
# multi-domain boot.
#
#   core "Pizzas" should not reference generic "Logging"
#
module Hecks
  module ValidationRules
    module References
      class SubdomainDirection < BaseRule
        def errors
          [] # Only warns
        end

        def warnings
          return [] unless multi_domain?
          result = []

          # Build subdomain map from all loaded domains
          subdomain_map = build_subdomain_map
          return [] if subdomain_map.values.compact.empty?

          @domain.aggregates.each do |agg|
            next unless agg.respond_to?(:references)
            agg.references.each do |ref|
              ref_name = ref.respond_to?(:type) ? ref.type : ref.to_s
              target_domain = find_domain_for(ref_name)
              next unless target_domain

              my_level = subdomain_level(subdomain_map[@domain.name])
              their_level = subdomain_level(subdomain_map[target_domain])

              if my_level < their_level && subdomain_map[@domain.name] && subdomain_map[target_domain]
                result << "Warning: #{@domain.name} (#{subdomain_map[@domain.name]}) " \
                          "depends on #{target_domain} (#{subdomain_map[target_domain]}) " \
                          "— core should not depend on generic"
              end
            end
          end

          result
        end

        private

        def multi_domain?
          Hecks.respond_to?(:bluebook_objects) && Hecks.bluebook_objects.respond_to?(:keys) && Hecks.bluebook_objects.keys.size > 1
        end

        def build_subdomain_map
          map = {}
          Hecks.bluebook_objects.each do |_mod, domain|
            map[domain.name] = domain.respond_to?(:subdomain) ? domain.subdomain : nil
          end
          map
        end

        def find_domain_for(aggregate_name)
          Hecks.bluebook_objects.each do |_mod, domain|
            return domain.name if domain.aggregates.any? { |a| a.name == aggregate_name }
          end
          nil
        end

        def subdomain_level(type)
          case type.to_s
          when "core" then 0
          when "supporting" then 1
          when "generic" then 2
          else 1 # unclassified = supporting
          end
        end
      end
      Hecks.register_validation_rule(SubdomainDirection)
    end
  end
end
