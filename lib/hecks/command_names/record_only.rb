require "hecks/naming"

module Hecks
  module CommandNames
    # The commands a domain declares for its records alone (`audience :record`, ADR 0163 point 4),
    # which no refusal may send a person or an agent to.
    module RecordOnly
      module_function

      # @param runtime [#bluebooks] what `Hecks.describe` answers
      # @return [Array<String>] each such command as the launcher lists it (`Release.mint`)
      def names(runtime)
        runtime.bluebooks.values.flat_map do |bluebook|
          bluebook.aggregates.flat_map { |aggregate| of(aggregate) }
        end
      end

      # @return [Array<String>] the aggregate's record-only commands, as listed
      def of(aggregate)
        aggregate.commands.select { |command| command.audience.map(&:to_s) == ["record"] }
                 .map { |command| "#{aggregate.hecks_name}.#{Naming.snake(command.hecks_name)}" }
      end
    end
  end
end
