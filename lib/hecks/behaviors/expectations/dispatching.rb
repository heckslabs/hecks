require_relative "../../runtime/reaction_invocation"

module Hecks
  module Behaviors
    module Expectations
      # Sends a verb to the booted runtime, and reads back what it settled. Extended onto
      # `Expectations`.
      module Dispatching
        # Reads the aggregate back from the repository, not `Result#state` — a
        # policy's own reentrant dispatch can re-save the record afterward.
        #
        # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's
        #   booted runtime
        # @param verb [String] the dispatched command's dotted FQN
        # @param result [Runtime::Dispatcher::Result, Runtime::RemoteDispatcher::Result]
        #   the dispatch's own result
        # @return [Hash{Symbol => Object}] the settled record's current state, read
        #   back from the repository; `result.state` (or `{}`) when the result has no
        #   id or the repository does not have that aggregate/record
        def settled_state(runtime, verb, result)
          record = settled_record(runtime, verb, result)
          record ? record.state : (result.state || {})
        end

        # @return [Runtime::Instance, nil] the repository's record for the dispatch's id, when the
        #   result has an id and the aggregate is declared
        def settled_record(runtime, verb, result)
          return unless result.respond_to?(:id) && result.id

          aggregate = verb_aggregate(runtime, verb)
          aggregate && runtime.registry.repository(verb.split("::", 2).first, aggregate).find(result.id)
        end

        # @return [Bluebook::Aggregate, nil] the aggregate a dotted verb names, when it is declared
        def verb_aggregate(runtime, verb)
          domain, rest = verb.split("::", 2)
          aggregate_name = rest.to_s.split(".", 2).first
          runtime.registry.bluebook(domain)&.aggregate(aggregate_name)
        end

        # Splits a mixed dispatch (receiver identity plus declared facts, e.g.
        # `to: { file: 2, rank: 2 }`) into the dispatcher's strict `to:`/`with:` envelope.
        #
        # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's booted runtime
        # @param verb [String] the command's dotted FQN, or a port operation's
        # @param args [Hash{Symbol => Object}] the facts, mixing identity and declared arguments
        # @return [Runtime::Dispatcher::Result, Runtime::RemoteDispatcher::Result] the dispatch
        #   result
        # @raise [Runtime::UnknownVerb] if `verb` names an undeclared construct
        # @raise [StandardError] any `Runtime::DOMAIN_REFUSALS` class, when the domain refuses
        def dispatch_command(runtime, verb, args)
          return runtime.dispatch_flat(verb, args) if port_operation?(runtime, verb)

          invocation = reaction_invocation(runtime, verb, args)
          return runtime.dispatch_flat(verb, args) unless invocation

          if invocation.key?(:to)
            runtime.dispatch(verb, to: invocation[:to], with: invocation[:with])
          else
            runtime.dispatch(verb, with: invocation[:with])
          end
        end

        # @return [Hash, nil] the strict envelope for `verb`, or nil when `verb` is not a declared
        #   command
        def reaction_invocation(runtime, verb, args)
          Runtime::ReactionInvocation.build(registry: runtime.registry, verb: verb,
                                            projected: args, explicit: true)
        rescue Runtime::UnknownVerb
          nil
        end

        # The same "Head.Rest" split `Dispatcher#dispatch` already uses — just a
        # domain/aggregate and port-name lookup, no command resolution needed.
        #
        # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the suite's
        #   booted runtime
        # @param verb [String] the verb to check, dotted FQN shaped
        # @return [Boolean] true if `verb` names a port operation on a declared aggregate
        def port_operation?(runtime, verb)
          domain, aggregate_name, command_path = Naming.split_verb(verb)
          return false unless command_path

          aggregate = runtime.registry.bluebook(domain)&.aggregate(aggregate_name)
          return false unless aggregate

          head, rest = command_path.split(".", 2)
          rest && !!aggregate.port(head)
        end
      end
    end
  end
end
