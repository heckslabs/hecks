require_relative "../adapters/driven/set_transform"
require_relative "../runtime/event"
require_relative "set_planner"

module Hecks
  module Bulk
    # A bulk run carried out as one statement (ADR 0129). Inside one transaction of the target's
    # repository it reads the query's rows, runs the statement, and records one event per updated
    # row and `emits`, with that event's outbox rows; after the commit each row's reactions are
    # delivered in query order. A row the statement skipped is the caller's to dispatch by hand.
    class SetSweep
      # What stops a statement before it commits, leaving the run to go row by row.
      FALLBACKS = [Adapters::SetTransform::Uncompilable, Adapters::SetTransform::Declined].freeze

      # @param registry [Runtime::Registry] the registry the run's domain is booted in
      # @param plan [Bulk::Plan] the run
      # @param planner [Bulk::SetPlanner] the run said as a statement
      # @param statement [Ports::Persistence::SetStatement] the statement the planner built
      def initialize(registry, plan, planner, statement)
        @registry = registry
        @plan = plan
        @planner = planner
        @statement = statement
        @domain, aggregate_name, command_name = Naming.split_verb(plan.verb)
        @aggregate = registry.bluebook(@domain).aggregate(aggregate_name)
        @emits = @aggregate.command(command_name).emits
        @repository = registry.repository(@domain, @aggregate)
      end

      # Runs the statement, or answers nil when the run must go row by row instead.
      #
      # @param read_ids [#call] answers the query's row identities, in query order
      # @yield [id] dispatches one row the statement skipped and answers its outcome
      # @return [Array<Hash{Symbol => Object}>, nil] one outcome per row in query order, or nil
      #   when nothing was committed
      def outcomes(read_ids)
        ids, updated = commit(read_ids)
        return nil unless ids

        updated.each_value { |events, rows| @registry.outbox.deliver(rows, events, @domain, @repository) }
        unread = updated.keys - ids.map(&:to_s)
        (ids + unread).map { |id| updated.key?(id.to_s) ? { row: id.to_s, delivered: true } : yield(id) }
      end

      private

      def commit(read_ids)
        @repository.transaction do
          ids = read_ids.call
          updated = in_query_order(@repository.apply_set_transform(@statement), ids.map(&:to_s))

          [ids, updated.to_h { |instance| [instance.id.to_s, record(instance)] }]
        end
      rescue *FALLBACKS
        nil
      end

      def in_query_order(instances, ids)
        positions = ids.each_with_index.to_h
        instances.sort_by { |instance| positions.fetch(instance.id.to_s, ids.size) }
      end

      # The events a row-by-row dispatch of this row emits, logged and recorded, with their
      # outbox rows enqueued in the statement's transaction.
      def record(instance)
        events = @emits.map do |name|
          Runtime::Event.new(name: name, occurred_at: Runtime::Event.stamp, aggregate: "#{@domain}::#{@aggregate.hecks_name}",
                             id: instance.id, payload: @planner.arguments.for_row(instance.id), correlation: nil)
        end
        events.each do |event|
          @registry.event_log << event.emit!
          @repository.record_event(event)
        end
        [events, @registry.outbox.enqueue(@repository, events, @domain)]
      end
    end
  end
end
