module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::TooManyCommands
    #
    # Advisory warning for aggregates that have an unusually large number of
    # commands. A high command count often indicates that the aggregate has
    # grown beyond a single bounded responsibility and should be split.
    #
    # Threshold is THRESHOLD = 10 commands.
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    # Example trigger:
    #   aggregate "Order" do
    #     # ... 10 or more command definitions ...
    #   end
    #
    # Would warn: "Order has 10 commands -- consider splitting into smaller aggregates"
    class TooManyCommands < BaseRule
      THRESHOLD = 10

      # Returns no errors. This rule only produces warnings.
      #
      # @return [Array<String>] always empty
      def errors
        []
      end

      # Returns a warning for each aggregate whose command count meets or
      # exceeds THRESHOLD.
      #
      # @return [Array<String>] warning messages
      def warnings
        result = []
        @domain.aggregates.each do |agg|
          if agg.commands.size >= THRESHOLD
            result << "#{agg.name} has #{agg.commands.size} commands -- consider splitting into smaller aggregates"
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(TooManyCommands)
    end
  end
end
