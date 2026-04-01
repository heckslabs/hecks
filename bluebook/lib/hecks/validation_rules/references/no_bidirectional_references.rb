module Hecks
  module ValidationRules
    module References

    # Hecks::ValidationRules::References::NoBidirectionalReferences
    #
    # Validates that no two aggregates reference each other (A->B and B->A).
    # Bidirectional references between aggregates create tight coupling and
    # make it impossible to determine ownership. The fix is to remove one
    # direction and use a policy to react to changes on the other side.
    #
    # Part of the ValidationRules::References group -- run by +Hecks.validate+.
    #
    # No A -> B and B -> A references allowed.
    class NoBidirectionalReferences < BaseRule
      # Builds a map of aggregate-to-reference-targets, then checks for any
      # pair where both sides reference each other. Deduplicates errors so
      # each bidirectional pair is reported only once (sorted alphabetically).
      #
      # @return [Array<String>] error messages for each bidirectional reference pair
      def errors
        result = []
        refs = {}
        @domain.aggregates.each do |agg|
          targets = (agg.references || []).map { |r| r.type.to_s }
          refs[agg.name] = targets
        end

        refs.each do |agg_name, targets|
          targets.each do |target|
            if refs[target]&.include?(agg_name)
              pair = [agg_name, target].sort
              msg = error("Bidirectional reference between #{pair[0]} and #{pair[1]}",
                hint: "Remove the reference from one side. Use a policy to react to changes on the other side")
              result << msg unless result.include?(msg)
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(NoBidirectionalReferences)
    end
  end
end
