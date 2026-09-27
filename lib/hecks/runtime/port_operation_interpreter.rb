require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "event"
require_relative "value"
require_relative "../naming"

module Hecks
  module Runtime
    # Dispatch pipeline for a port operation, called by an adapter outside the bluebook.
    # A trimmed CommandInterpreter: argument gate and coercion, but no `given`, mutations or save.
    class PortOperationInterpreter
      include Interpreting
      include CommandInterpreter::ArgumentGate

      Context = Struct.new(:domain, :aggregate, :operation, :args, :route, :instance, :result, :invocation)

      DISPATCH_ORDER = %i[
        refuse_unknown_arguments refuse_absent_arguments normalize_args resolve_references resolve_route emit
      ].freeze

      # @param registry [Runtime::Registry] the booted registry this interpreter dispatches
      #   against
      # @param rules [Runtime::CommandRules] the shared command-rule checks (references) this
      #   interpreter's steps call
      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      # `ctx.args` is the invocation's `to_args`, `ctx.route` its `target`.
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate the port operation belongs to
      # @param operation [Bluebook::PortOperation] the port operation to dispatch
      # @param invocation [Runtime::Invocation] the invocation `Dispatcher` built for this call
      # @return [Array<Runtime::Event>] `emits` (inbound), or one `answers`/`refuses`
      #   event (outbound; an adapter failure is recorded as `refuses`, not raised)
      # @raise [Runtime::UnknownArgument] if `invocation` offers an undeclared argument
      # @raise [Runtime::AbsentArgument] if `invocation` omits a non-optional declared argument
      # @raise [Runtime::TypeMismatch] if an offered argument does not coerce to its declared type
      # @raise [Runtime::NotFound] if an offered reference or the receiving record is missing
      def call(domain, aggregate, operation, invocation)
        ctx = Context.new(domain, aggregate, operation, invocation.to_args)
        ctx.invocation = invocation
        ctx.route = invocation.target
        run_dispatch_order(DISPATCH_ORDER, ctx)
        ctx.result
      end

      private

      def step_refuse_unknown_arguments(ctx)
        step(:refuse_unknown_arguments) { refuse_unknown_arguments(ctx.domain, ctx.aggregate, ctx.operation, ctx.args) }
      end

      def step_refuse_absent_arguments(ctx)
        step(:refuse_absent_arguments) { refuse_absent_arguments(ctx.operation, ctx.args, aggregate: ctx.aggregate) }
      end

      def step_normalize_args(ctx)
        ctx.args = step(:normalize_args) { normalize_args(ctx.aggregate, ctx.operation, ctx.args) }
      end

      def step_resolve_references(ctx)
        step(:resolve_references) { @rules.resolve_references(ctx.domain, ctx.operation, ctx.args) }
      end

      def step_resolve_route(ctx)
        ctx.instance = step(:resolve_route) do
          @registry.repository(ctx.domain, ctx.aggregate).find(ctx.route.aggregate) ||
            raise(NotFound, "#{ctx.aggregate.hecks_name} #{ctx.route.aggregate.inspect} does not exist")
        end
      end

      def step_emit(ctx)
        ctx.result = step(:emit) { ctx.operation.outbound? ? ask(ctx) : emit(ctx) }
      end

      # The domain calling out. Any failure, however wide (timeout, bad credential, missing
      # adapter), becomes the `refuses` event rather than a raise, so a policy can react to it.
      # The adapter is found by port name across the adapters this boot loaded.
      #
      # Unlike an inbound operation, an ask is handed the record's held state: the adapter
      # needs data that lives on the record, and an event payload carries only arguments.
      # Arguments win over state.
      def ask(ctx)
        payload = held_state(ctx).merge(materialise(ctx.args))
        answer  = adapter_for(ctx).public_send(Naming.snake(ctx.operation.hecks_name), **payload)
        announce(ctx, ctx.operation.answers, ctx.args.merge(spread(answer)))
      rescue StandardError => e
        announce(ctx, ctx.operation.refuses, ctx.args.merge(refusal: { value: "#{e.class}: #{e.message}" }))
      end

      # The answer is spread, not nested: a policy re-enters its target with the event
      # payload verbatim and cannot reach inside a key. The adapter's keys are therefore the
      # arguments of the reacting command, in the shape the runtime coerces
      # (`{ number: { value: 43 } }`, not `43`). A non-Hash answer is kept under `answered:`.
      def spread(answer)
        return { answered: answer } unless answer.is_a?(Hash)

        answer.to_h { |key, value| [key.to_sym, deep_symbolize(value)] }
      end

      def deep_symbolize(value)
        case value
        when Hash  then value.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
        when Array then value.map { |element| deep_symbolize(element) }
        else value
        end
      end

      # The record, if there is one. A missing record is not an error here: the ask still
      # goes with only its arguments, since `resolve_references` already checked existence.
      def held_state(ctx)
        ctx.instance ? Value.materialize(ctx.instance.state) : {}
      rescue StandardError
        {}
      end

      # The port this operation belongs to, found through the aggregate rather than
      # threaded through the call.
      def port_name_for(ctx)
        owning = ctx.aggregate.ports.find { |port| port.operations.any? { |op| op.equal?(ctx.operation) } }
        owning&.name or raise WiringError,
                              "#{ctx.operation.hecks_name} belongs to no port on #{ctx.aggregate.hecks_name}"
      end

      def adapter_for(ctx)
        name = port_name_for(ctx)
        implementations = @registry.adapters.values.select { |adapter| adapter.port == name }

        case implementations.size
        when 1 then Adapters.const_get(implementations.first.name).new
        when 0 then raise WiringError, "no adapter implements the #{name} port — nothing can answer #{ctx.operation.hecks_name}"
        else raise WiringError,
                   "#{implementations.size} adapters implement the #{name} port " \
                   "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end

      # Adapters are handed plain data, never a Value.
      def materialise(args) = Value.materialize(args)

      def announce(ctx, event_name, payload)
        event = Event.new(
          name:        event_name,
          aggregate:   "#{ctx.domain}::#{ctx.aggregate.hecks_name}",
          id:          ctx.route.aggregate,
          payload:     payload,
          occurred_at: Time.now.utc.iso8601
        )
        @registry.event_log << event
        [event]
      end

      # Unlike CommandRules::Emission there is no mutated instance to read an id off; the
      # event is stamped with the coerced reference to the owning aggregate (already a plain id).
      def emit(ctx)
        ctx.operation.emits.map do |event_name|
          event = Event.new(
            name:        event_name,
            aggregate:   "#{ctx.domain}::#{ctx.aggregate.hecks_name}",
            id:          ctx.route.aggregate,
            payload:     ctx.args,
            occurred_at: Time.now.utc.iso8601
          )
          @registry.event_log << event.emit!
          event
        end
      end
    end
  end
end
