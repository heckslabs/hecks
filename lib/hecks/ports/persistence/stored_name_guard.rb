require_relative "../../runtime/errors"

module Hecks
  module Ports
    module Persistence
      # Refuses the boot that would store an aggregate in a new, empty table beside rows an earlier
      # name still holds. A renamed aggregate's rows are found by its `stored_as`; if that line is
      # missing or wrong, the adapter would create the empty table the new name implies and the
      # rows would seem gone. This names the table the rows are in instead, and creates nothing.
      module StoredNameGuard
        module_function

        # @param aggregate [Bluebook::Aggregate] the aggregate about to be stored
        # @param row_count [#call] given a table's base name, the rows it holds (0 when absent)
        # @return [void]
        # @raise [Runtime::WiringError] when the aggregate's own table holds no rows and a prior
        #   name's table does
        def check!(aggregate, row_count:)
          return if row_count.call(aggregate.storage_name).positive?

          held = aggregate.prior_storage_names.to_h { |name| [name, row_count.call(name)] }.select { |_, rows| rows.positive? }
          return if held.empty?

          raise Runtime::WiringError, refusal(aggregate, held)
        end

        def refusal(aggregate, held)
          name, rows = held.first
          "cannot boot #{aggregate.name}: it would be stored in #{aggregate.storage_name.inspect}, which holds no rows, " \
            "but #{name.inspect} holds rows (#{rows}) from an earlier name. Point the world at them with " \
            "`stored_as #{aggregate.name}: #{name.inspect}`, or move the rows first. Nothing was created."
        end
      end
    end
  end
end
