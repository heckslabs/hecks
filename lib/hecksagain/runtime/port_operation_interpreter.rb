require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "event"

module Hecksagain
  module Runtime
    # The dispatch pipeline for a port operation — called by an adapter living
    # outside the bluebook entirely, never by the domain itself. Deliberately
    # a trimmed CommandInterpreter: the same payload gate and coercion
    # (ArgumentGate, Interpreting#normalize_args), but no `given`, no
    # `mutations`, no lifecycle, no save. A port operation does not act on an
    # aggregate instance — it translates an external call into an event in
    # this domain's own vocabulary, and whatever mutation follows happens
    # wherever a `policy` reacts to that event, exactly as it would for any
    # command-emitted one.
    class PortOperationInterpreter
      include Interpreting
      include CommandInterpreter::ArgumentGate

      Context = Struct.new(:domain, :aggregate, :operation, :args, :result)

      DISPATCH_ORDER = %i[
        refuse_unknown_arguments refuse_absent_arguments normalize_args resolve_references emit
      ].freeze

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, operation, args)
        ctx = Context.new(domain, aggregate, operation, args)
        run_dispatch_order(DISPATCH_ORDER, ctx)
        ctx.result
      end

      private

      def step_refuse_unknown_arguments(ctx)
        step(:refuse_unknown_arguments) { refuse_unknown_arguments(ctx.domain, ctx.aggregate, ctx.operation, ctx.args) }
      end

      def step_refuse_absent_arguments(ctx)
        step(:refuse_absent_arguments) { refuse_absent_arguments(ctx.operation, ctx.args) }
      end

      def step_normalize_args(ctx)
        ctx.args = step(:normalize_args) { normalize_args(ctx.aggregate, ctx.operation, ctx.args) }
      end

      def step_resolve_references(ctx)
        step(:resolve_references) { @rules.resolve_references(ctx.domain, ctx.operation, ctx.args) }
      end

      def step_emit(ctx)
        ctx.result = step(:emit) { emit(ctx) }
      end

      # THE ONE PLACE THIS DIFFERS FROM CommandRules::Emission — there is no
      # mutated instance to read an id off, because nothing was hydrated or
      # saved. The record this event is ABOUT is named by whichever attribute
      # is a reference to the owning aggregate (PortOperationBuilder#build
      # already refused to build an operation with none), so its coerced
      # value — already a plain id, never an object, per
      # Value::Coercion#refuse_object_reference — is what stamps the event.
      def emit(ctx)
        identity_attribute = ctx.operation.identity_attribute(ctx.aggregate.hecks_name)
        id = ctx.args[identity_attribute.name]

        ctx.operation.emits.map do |event_name|
          event = Event.new(
            name:        event_name,
            aggregate:   "#{ctx.domain}::#{ctx.aggregate.hecks_name}",
            id:          id,
            payload:     ctx.args,
            occurred_at: Time.now.utc.iso8601
          )
          @registry.event_log << event
          event
        end
      end
    end
  end
end
