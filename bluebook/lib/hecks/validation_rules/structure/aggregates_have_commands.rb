module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::AggregatesHaveCommands
    #
    # Validates that every aggregate has at least one command. An aggregate
    # without commands is a data bag with no behavior boundary -- it should
    # either have commands added or be modeled as a value object.
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    # Every aggregate should have at least one command.
    class AggregatesHaveCommands < BaseRule
      # Checks each aggregate and reports an error if it has no commands.
      # The error message includes a suggestion for a minimal command definition.
      #
      # @return [Array<String>] error messages for aggregates without commands
      def errors
        result = []
        @domain.aggregates.each do |agg|
          if agg.commands.empty?
            result << error("#{agg.name} has no commands",
              hint: "Add at least one command: command 'Create#{agg.name}' do attribute :name, String end")
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(AggregatesHaveCommands)
    end
  end
end
