require_relative "../runtime/caller"
require_relative "../runtime/dispatcher"
require_relative "../runtime/row_sweep"
require_relative "plan"
require_relative "set_sweep"

module Hecks
  module Bulk
    # One bulk run carried out: reads the rows of the run's query once, then sends the run's
    # command to each row through {Runtime::RowSweep}, under the caller the run was asked by
    # (ADR 0125). Answers one outcome per row in the order the query answered them.
    class Sweep
      # @param registry [Runtime::Registry] the registry the run's domain is booted in
      # @param plan [Bulk::Plan] the run
      # @param set_transform [Boolean] whether the run may go as one statement when its store
      #   provides `set_transform` (ADR 0129); false sends every row by hand
      def initialize(registry, plan, set_transform: true)
        @registry   = registry
        @plan       = plan
        @set_transform = set_transform
        @rows       = Runtime::RowSweep.new(registry)
        @dispatcher = Runtime::Dispatcher.new(registry)
        @origin     = Runtime::Caller.origin
      end

      # Sends the command to every row and answers how each came out.
      #
      # @return [Array<Hash{Symbol => Object}>] one `{ row:, delivered: }` per row, with `reason:`
      #   when it was not delivered
      # @raise [Runtime::UnknownVerb] if the verb or the query does not resolve
      # @raise [ArgumentError] if no key of the command addresses a row of the query
      def outcomes
        key, read_ids = prepare
        as_requester { compiled_outcomes(key, read_ids) } || row_outcomes(key, read_ids.call)
      end

      private

      # The key a row addresses the command by, and how to read the rows' identities once.
      def prepare
        domain, aggregate_name, query_name = @plan.query_route
        aggregate = @rows.query_aggregate(domain, aggregate_name, verb: @plan.over)
        key = @rows.addressing_key_for(@plan.verb, aggregate_name, label: "the bulk run's verb")

        args = @plan.query_arguments(aggregate.query(query_name))
        [key, -> { @rows.rows(domain, aggregate, query_name, args).map { |row| row[:id] } }]
      end

      def row_outcomes(key, ids) = ids.map { |id| send_row(id, key) }

      # The run as one statement when it can be (ADR 0129), else nil.
      def compiled_outcomes(key, read_ids)
        return nil unless @set_transform

        planner = SetPlanner.new(@registry, @plan, key)
        statement = planner.statement
        statement && SetSweep.new(@registry, @plan, planner, statement).outcomes(read_ids) { |id| send_row(id, key) }
      end

      def send_row(id, key)
        as_requester { @rows.deliver({ row: id.to_s }) { @dispatcher.dispatch_flat(@plan.verb, key => id) } }
      end

      def as_requester(&) = Runtime::Caller.restoring(@origin, &)
    end
  end
end
