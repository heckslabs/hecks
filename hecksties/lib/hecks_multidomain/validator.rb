# Hecks::MultiDomain::Validator
#
# Validates references that cross domain boundaries. Qualified references
# (+reference_to "Billing::Invoice"+) are allowed when the target domain is
# loaded. Unqualified references that happen to match a foreign aggregate
# are rejected — the developer must qualify the path explicitly.
#
#   Hecks::MultiDomain::Validator.validate_no_cross_domain_references(domains)
#
module Hecks
  module MultiDomain
    # Hecks::MultiDomain::Validator
    #
    # Validates cross-domain references: allows qualified paths, rejects unqualified foreign aggregate refs.
    #
    module Validator
      extend HecksTemplating::NamingHelpers
      module_function

      # Returns warnings for aggregate names that appear in more than one bounded
      # context. Shared names across contexts suggest ambiguous ubiquitous language
      # that should be clarified with a context-specific prefix or rename.
      #
      # @param domains [Array<Hecks::DomainModel::Structure::Domain>]
      # @return [Array<String>] warning messages
      def ambiguous_name_warnings(domains)
        name_to_contexts = Hash.new { |h, k| h[k] = [] }
        domains.each do |domain|
          domain.aggregates.each do |agg|
            name_to_contexts[agg.name] << domain.name
          end
        end
        name_to_contexts.each_with_object([]) do |(name, contexts), warnings|
          if contexts.size > 1
            warnings << "Aggregate name '#{name}' appears in multiple bounded contexts (#{contexts.join(', ')}) -- consider a context-specific name to clarify ubiquitous language"
          end
        end
      end

      def validate_no_cross_domain_references(domains)
        errors = []
        domain_names = domains.map(&:name)
        domains.each do |domain|
          own_aggs = domain.aggregates.map(&:name)
          domain.aggregates.each do |agg|
            (agg.references || []).each do |ref|
              ref_name = ref.type.to_s

              if ref.domain
                # Qualified cross-domain reference — verify the target domain is loaded
                unless domain_names.include?(ref.domain)
                  errors << "#{domain.name}::#{agg.name} uses reference_to(\"#{ref.domain}::#{ref_name}\") " \
                            "but domain '#{ref.domain}' is not loaded. Loaded domains: #{domain_names.join(', ')}"
                end
                next
              end

              next if own_aggs.include?(ref_name)
              owner = domains.find { |d| d.aggregates.any? { |a| a.name == ref_name } }
              if owner
                errors << "#{domain.name}::#{agg.name} uses reference_to(\"#{ref_name}\") " \
                          "which belongs to #{owner.name}. " \
                          "Qualify the reference: reference_to \"#{owner.name}::#{ref_name}\""
              end
            end
          end
        end
        unless errors.empty?
          raise Hecks::ValidationError, "Cross-domain reference_to errors:\n#{errors.map { |e| "  - #{e}" }.join("\n")}"
        end
      end
    end
  end
end
