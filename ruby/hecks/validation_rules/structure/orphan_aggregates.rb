module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::OrphanAggregates
    #
    # Warns about aggregates that have commands but no way to create instances.
    # An aggregate with behavior but no creation command is likely missing a
    # "Create" command definition.
    #
    # Skips aggregates with no commands at all (CRUD capability may add them later).
    # Only warns when commands exist but none start with "Create".
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    #   rule = OrphanAggregates.new(domain)
    #   rule.errors  # => ["Warning: Aggregate 'Report' has commands but no Create command"]
    #
    class OrphanAggregates < BaseRule
      # Returns no errors. This rule only produces warnings.
      #
      # @return [Array] always returns an empty array
      def errors
        []
      end

      # Checks each aggregate for a creation command and returns warnings
      # for aggregates that have commands but none that create instances.
      #
      # @return [Array<String>] warning messages for orphan aggregates
      def warnings
        result = []

        @domain.aggregates.each do |agg|
          next if agg.commands.empty?

          has_create = agg.commands.any? { |cmd| cmd.name.to_s.start_with?("Create") }
          next if has_create

          result << "Warning: Aggregate '#{agg.name}' has commands but no Create command -- " \
                    "instances cannot be constructed. " \
                    "Add a command like 'Create#{agg.name}' with the required attributes."
        end

        result
      end
    end
    Hecks.register_validation_rule(OrphanAggregates)
    end
  end
end
