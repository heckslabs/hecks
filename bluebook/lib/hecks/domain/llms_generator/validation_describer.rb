module Hecks
  class LlmsGenerator
    # Hecks::LlmsGenerator::ValidationDescriber
    #
    # Renders validation rules and invariants for an aggregate as plain-text
    # lines for an llms.txt document.
    #
    #   class MyGenerator
    #     include ValidationDescriber
    #   end
    #
    module ValidationDescriber
      private

      # @return [Array<String>]
      def describe_validations(agg)
        validations = agg.validations
        return [] if validations.empty?

        lines = ["### Validation Rules", ""]
        validations.each { |v| lines << "- #{v.field}: #{summarize_rules(v.rules)}" }
        lines << ""
        lines
      end

      # @return [String]
      def summarize_rules(rules)
        parts = []
        parts << "must be present" if rules[:presence]
        parts << "must be #{rules[:type]}" if rules[:type]
        parts << "must be unique" if rules[:uniqueness]
        rules.each do |rule, value|
          next if %i[presence type uniqueness].include?(rule)
          parts << "#{rule}: #{value}"
        end
        parts.join(", ")
      end

      # @return [Array<String>]
      def describe_invariants(agg)
        invariants = agg.invariants
        return [] if invariants.empty?

        lines = ["### Invariants", ""]
        invariants.each { |inv| lines << "- #{inv.message}" }
        lines << ""
        lines
      end
    end
  end
end
