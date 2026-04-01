module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::CommandsHaveAttributes
    #
    # Validates that every command has at least one attribute. A command with
    # no attributes carries no data and cannot meaningfully modify an aggregate.
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    # Commands must have at least one attribute.
    class CommandsHaveAttributes < BaseRule
      # Checks each command within each aggregate and reports an error
      # if the command has no attributes.
      #
      # @return [Array<String>] error messages for commands without attributes
      def errors
        result = []
        @domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            if cmd.attributes.empty? && (cmd.references || []).empty?
              result << error("Command #{cmd.name} in #{agg.name} has no attributes",
                hint: "Add at least one attribute: attribute :name, String")
            end
          end
        end
        result
      end
    end
    Hecks.register_validation_rule(CommandsHaveAttributes)
    end
  end
end
