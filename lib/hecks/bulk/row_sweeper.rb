require_relative "../runtime/asking"
require_relative "sweep"

module Hecks
  module Adapters
    # The `Rows` port's adapter for a `BulkRun` (ADR 0125): sends the run's command to every row
    # of its query in this process, through the boot whose `BulkRun` asked, and answers each
    # row's outcome. A run that cannot start (a mode the store cannot honour, a verb or query
    # that does not resolve) raises, and the port records the refusal on the run.
    class RowSweeper
      # Raised when the adapter is asked outside a port operation, with no boot to send rows to.
      class Unbound < StandardError; end

      # Sends the run's command to every row.
      #
      # @param held [Hash{Symbol => Object}] the run's record: `verb`, `over`, `arguments`, `mode`
      # @return [Hash{Symbol => Array<Hash>}] `results:` one `RowResult` per row: `row:`,
      #   `outcome:` ("delivered" or "refused") and, when refused, `reason:`
      # @raise [Unbound] if no registry is asking
      # @raise [Bulk::Sweep::Declined] if the mode cannot run against the command's store
      def sweep(**held)
        registry = Runtime::Asking.registry or raise Unbound, "a bulk run is swept only when its BulkRun asks"

        { results: Bulk::Sweep.new(registry, Bulk::Plan.from_record(held)).outcomes.map { |row| row_result(row) } }
      end

      private

      # A row's outcome in the shape the chapter's `RowResult` holds.
      def row_result(row)
        { row: row[:row], outcome: row[:delivered] ? "delivered" : "refused", reason: row[:reason] }.compact
      end
    end
  end
end
