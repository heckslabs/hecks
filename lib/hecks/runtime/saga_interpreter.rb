require "json"
require_relative "saga_interpreter/correlation"
require_relative "saga_interpreter/lifecycle"
require_relative "saga_interpreter/transitions"
require_relative "saga_interpreter/delivery"
require_relative "saga_interpreter/compensation"
require_relative "../bluebook/process_manager"
require_relative "errors"
require_relative "reaction_invocation"
require_relative "value"
require_relative "saga_pending_dispatch"
require_relative "saga_interpreter/redrive"
require_relative "outbox"

module Hecks
  module Runtime
    # Runs one domain's declared process managers against a just-emitted
    # event, checkpointing each transition durably before its dispatches run.
    class SagaInterpreter
      include Correlation
      include Lifecycle
      include Transitions
      include Delivery
      include Compensation
      include Redrive

      # The trigger lives on the declaration it triggers — see ProcessManager::REFUSED.
      REFUSED = Bluebook::ProcessManager::REFUSED

      # A crash gets this many retries before it's treated as something to
      # compensate for, instead of unwinding on the first failure.
      MAX_DEFECT_RETRIES = 3

      # One transition of one saga instance: the declaration, the event that moves it, the
      # instance's correlation, the log record of the move, and — once a leg is taken under the
      # mutex — the instance, the leg's handler and the state it left.
      Leg = Struct.new(:process_manager, :event, :domain, :correlation, :record, :instance, :handler, :pre_state) do
        # @return [String] the declared name of the saga this leg moves
        def saga_name = process_manager.name

        # @return [Symbol, String] the field the saga correlates its instances on
        def correlation_head = process_manager.correlation_head

        # @return [String] the name of the event that moves this leg
        def event_name = event.name

        # @return [Hash] the moving event's payload
        def event_payload = event.payload

        # @return [Hash{Symbol => Object}] the moving event's aggregate and identity, the
        #   receiver a reentered command may fall back to
        def event_source = { aggregate: event.aggregate, identity: event.id }

        # @return [Array] the dispatches the taken handler declares
        def dispatches = handler.dispatches

        # Moves the instance into the handler's state, remembering the state it left.
        #
        # @param leg_handler [Bluebook::ProcessManager::Handler] the leg being taken
        # @return [void]
        def take(leg_handler)
          self.handler   = leg_handler
          self.pre_state = instance[:state]
          instance[:state] = leg_handler.to_state
        end

        # How far the leg's dispatches got: how many have settled, and whether the next one has
        # been started, so a crash can tell a dispatch that never began from one that may have run.
        #
        # @return [Hash{Symbol => Object}] `:settled` count and `:attempting` flag
        def progress = (@progress ||= { settled: 0, attempting: false })

        # What a crash between the checkpoint and the dispatches leaves behind, to be redriven on
        # the next boot. Carries the moving event, so the dispatches' arguments can be resolved again.
        #
        # @return [Hash{Symbol => Object}] the event, the states moved between, the commands, and progress
        def pending_marker
          { on: event.name, from: pre_state, to: instance[:state], dispatches: handler.dispatches.map(&:command_name),
            event: Outbox.serialize_event(event) }.merge(progress)
        end
      end

      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry whose declared
      #   process managers and saga persistence this interpreter runs against
      # @param dispatcher [Runtime::Dispatcher] the dispatcher a saga leg's own dispatch
      #   re-enters through
      def initialize(registry, dispatcher:)
        @registry = registry
        @dispatcher = dispatcher
      end

      # Runs `domain`'s declared process managers against `event`: begins,
      # advances or ends each matching saga instance.
      #
      # @param event [Runtime::Event] the just-emitted event to react to
      # @param domain [String, Symbol] the domain whose declared process managers
      #   are checked
      # @param only [Bluebook::ProcessManager, nil] one process manager to run
      #   exactly, instead of every manager `domain` declares
      # @return [void]
      def advance(event, domain, only: nil)
        bluebook = @registry.bluebook(domain)
        return unless bluebook

        (only ? [only] : bluebook.process_managers).each do |process_manager|
          begin_saga(process_manager, event, domain)
          advance_saga(process_manager, event, domain)
          end_saga(process_manager, event, domain)
        end
      end

      private

      # Holds `saga_mutex` across both the in-memory mutation and the
      # persistence write, never just the mutation — otherwise two threads
      # racing the same (process_manager, correlation) key could interleave
      # their writes out of order. `pending:` is injected into the written
      # copy only, never into `instance[:memory]` itself.
      def checkpoint(process_manager, correlation, instance, domain, pending: nil)
        memory = deep_copy(instance[:memory])
        memory[SAGA_PENDING_DISPATCH_KEY] = pending if pending
        @registry.saga_persistence(domain).save_saga(
          process_manager: process_manager.name, correlation: correlation,
          state: instance[:state], memory: memory,
          completed_compensations: deep_copy_array(instance[:completed_compensations])
        )
      end

      # The checkpoint of the instance a leg is moving.
      def checkpoint_leg(leg, pending: nil)
        checkpoint(leg.process_manager, leg.correlation, leg.instance, leg.domain, pending: pending)
      end

      # Appends the leg's log record, with `fields` merged over it.
      def log_leg(leg, fields)
        @registry.saga_log << leg.record.merge(fields)
      end

      # Wrapped in a Hash before the round-trip since `JSON.parse` only
      # accepts an object at the top level. `|| []` rehydrates a ledger
      # that has never completed a compensable leg to empty, never nil.
      def deep_copy_array(array) = deep_copy(list: array || [])[:list]

      def deep_copy(hash) = JSON.parse(JSON.generate(hash), symbolize_names: true)
    end
  end
end
