require_relative "../naming"
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
      # A run that cannot start, raised before any row is read or sent.
      class Declined < StandardError; end

      # Raised inside an all_or_nothing transaction when a row refuses after every row was
      # checked, so the store rolls the rows already sent back.
      class RolledBack < StandardError
        # @return [Hash{Symbol => Object}] the refusing row's outcome
        attr_reader :outcome

        # @param outcome [Hash{Symbol => Object}] the refusing row's outcome
        def initialize(outcome)
          super(outcome[:reason])
          @outcome = outcome
        end
      end

      # Why `plan`'s mode cannot run against the store its command writes to, or nil when it can.
      # all_or_nothing needs the `:rollback` persistence capability.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param plan [Bulk::Plan] the run
      # @return [String, nil] the reason, naming the store; nil when the mode can run
      def self.mode_refusal(registry, plan)
        return nil unless plan.all_or_nothing?

        repository = target_repository(registry, plan.verb)
        return nil if repository.capabilities.include?(:rollback)

        domain, aggregate_name, = Naming.split_verb(plan.verb)
        "all_or_nothing needs a store that can roll back; #{domain}::#{aggregate_name} is persisted by " \
          "#{Naming.demodulise(repository.adapter.class)}, which cannot. Run it best_effort, or bind a store " \
          "that rolls back (Sqlite, Postgres)."
      end

      # The repository the run's command writes to.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param verb [String] the command's verb, `"Domain::Aggregate.Command"`
      # @return [Ports::Persistence::AppendOnly] the command's aggregate's repository
      def self.target_repository(registry, verb)
        domain, aggregate_name, = Naming.split_verb(verb)
        registry.repository(domain, registry.bluebook(domain).aggregate(aggregate_name))
      end

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
      # @raise [Declined] if the mode cannot run against the command's store
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
        refusal = self.class.mode_refusal(@registry, @plan)
        raise Declined, refusal if refusal

        args = @plan.query_arguments(aggregate.query(query_name))
        [key, -> { @rows.rows(domain, aggregate, query_name, args).map { |row| row[:id] } }]
      end

      def row_outcomes(key, ids)
        @plan.all_or_nothing? ? all_or_nothing(ids, key) : ids.map { |id| send_row(id, key) }
      end

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

      def check_row(id, key)
        as_requester { @rows.deliver({ row: id.to_s }) { @dispatcher.dry_run?(@plan.verb, key => id) } }
      end

      def as_requester(&) = Runtime::Caller.restoring(@origin, &)

      # Every row checked first; sent only when all would pass, inside one transaction.
      def all_or_nothing(ids, key)
        checks = ids.map { |id| check_row(id, key) }
        refused = checks.find { |check| !check[:delivered] }
        return stopped(checks, refused, "not sent") if refused

        send_together(ids, key)
      rescue RolledBack => e
        stopped(checks, e.outcome, "rolled back")
      end

      def send_together(ids, key)
        self.class.target_repository(@registry, @plan.verb).transaction { ids.map { |id| send_or_roll_back(id, key) } }
      end

      def send_or_roll_back(id, key)
        outcome = send_row(id, key)
        raise RolledBack, outcome unless outcome[:delivered]

        outcome
      end

      # Every outcome as not delivered: the refusing row keeps its reason, the others name it.
      def stopped(outcomes, refused, verdict)
        outcomes.map do |outcome|
          next refused if outcome[:row] == refused[:row]

          { row: outcome[:row], delivered: false, reason: "#{verdict}: row #{refused[:row]} refused (#{refused[:reason]})" }
        end
      end
    end
  end
end
