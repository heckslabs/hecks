module Hecks
  module ValidationRules
    module References

    # Hecks::ValidationRules::References::ValidReferences
    #
    # Validates that all +reference_to+ attributes target existing aggregate roots.
    # Catches three kinds of mistakes:
    # 1. Referencing a value object instead of an aggregate root
    # 2. Referencing an entity instead of an aggregate root
    # 3. Referencing a name that does not exist in the domain at all
    #
    # Each error includes an actionable hint (promote to aggregate, reference
    # the owning aggregate, or lists available aggregates).
    #
    # Part of the ValidationRules::References group -- run by +Hecks.validate+.
    #
    # References must target aggregate roots.
    class ValidReferences < BaseRule
      # Checks each aggregate's reference attributes to ensure they point at
      # existing aggregate roots (not value objects, entities, or unknown names).
      #
      # @return [Array<String>] error messages for invalid references
      def errors
        result = []
        all_aggregate_names = @domain.aggregates.map(&:name)
        all_vo_names = @domain.aggregates.flat_map { |a| a.value_objects.map(&:name) }
        all_entity_names = @domain.aggregates.flat_map { |a| a.entities.map(&:name) }

        @domain.aggregates.each do |agg|
          (agg.references || []).each do |ref|
            # Cross-domain qualified references (ref.domain non-nil) are validated
            # at boot time by the multi-domain validator, not at compile time.
            next if ref.domain

            ref_name = ref.type.to_s

            # Check if referencing a value object instead of an aggregate
            if all_vo_names.include?(ref_name) && !all_aggregate_names.include?(ref_name)
              result << error("#{agg.name} references #{ref_name} which is a value object, not an aggregate root",
                hint: "Move #{ref_name} to its own aggregate or reference the aggregate that owns it")
              next
            end

            # Check if referencing an entity instead of an aggregate
            if all_entity_names.include?(ref_name) && !all_aggregate_names.include?(ref_name)
              result << error("#{agg.name} references #{ref_name} which is an entity, not an aggregate root",
                hint: "Promote #{ref_name} to its own aggregate or reference the aggregate that owns it")
              next
            end

            if all_aggregate_names.include?(ref_name)
              next # valid: same domain aggregate root
            end

            available = all_aggregate_names.reject { |n| n == agg.name }
            fix = available.any? ? "Available aggregates: #{available.join(', ')}" : "Define the target aggregate first"
            result << error("#{agg.name} references unknown aggregate: #{ref_name}", hint: fix)
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(ValidReferences)
    end
  end
end
