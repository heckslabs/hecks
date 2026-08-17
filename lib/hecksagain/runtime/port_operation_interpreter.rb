require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "event"
require_relative "value"
require_relative "../naming"

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
        ctx.result = step(:emit) { ctx.operation.outbound? ? ask(ctx) : emit(ctx) }
      end

      # THE DOMAIN CALLING OUT, AND BOTH ENDINGS RECORDED.
      #
      # The adapter is found the same way every other port's is — by name,
      # across whatever adapters this boot loaded — so an `asks` is bound by
      # an adapter declaring `port "IssueTracker"` and nothing new to learn.
      #
      # EVERY FAILURE IS AN ANSWER. A raise from the far side of a boundary is
      # not an exception in this domain's terms, it is the outside saying no,
      # and the chapter already named the word for that. So the rescue is
      # deliberately wide: a timeout, a bad credential, an adapter that does
      # not exist, a nil where a number was wanted — all of them become the
      # `refuses` event, carrying what was said. A policy reacts to it, a
      # retry counter reads it, and nothing has to catch anything.
      #
      # AN ASK IS HANDED THE RECORD IT IS ABOUT.
      #
      # An INBOUND operation deliberately cannot read state — it is the
      # anti-corruption boundary, translating a fact from outside, and letting
      # it read the aggregate would make it a second place rules live. That
      # rule was written for that direction and does not survive the crossing.
      #
      # An outbound one almost always needs the record. `asks "File"` names
      # `reference_to Ticket` and the adapter needs the ticket's repository,
      # title and body — which are ON the ticket, and which the policy that
      # triggered this cannot supply because a command's event payload is its
      # ARGUMENTS, not its state. Without this, every ask would have to have
      # its data re-passed through the command that fired it, so the same text
      # would live in two places and could differ.
      #
      # ARGUMENTS WIN over state, because an argument is what THIS call said
      # and state is what the record happens to hold.
      def ask(ctx)
        payload = held_state(ctx).merge(materialise(ctx.args))
        answer  = adapter_for(ctx).public_send(Naming.snake(ctx.operation.hecks_name), **payload)
        announce(ctx, ctx.operation.answers, ctx.args.merge(spread(answer)))
      rescue StandardError => e
        announce(ctx, ctx.operation.refuses, ctx.args.merge(refusal: { value: "#{e.class}: #{e.message}" }))
      end

      # THE ANSWER IS SPREAD, NOT NESTED — and that is what makes the loop
      # close. A policy re-enters its target with the event payload VERBATIM;
      # it cannot reach inside a key. So an answer tucked under `answered:`
      # can be read by a human and by nothing else, and the command that
      # should record the issue number never gets one.
      #
      # Spread, the adapter's own keys ARE the arguments of whatever command
      # reacts to the answering event. Which is a real contract on the adapter
      # — it must return what that command takes, in the shape the runtime
      # coerces (`{ number: { value: 43 } }`, not `43`) — and naming it here
      # is cheaper than a mapping layer nobody could see into.
      #
      # A non-Hash answer keeps the old shape: a port that returns a URL
      # string has nothing to spread, and `answered:` is the honest word for
      # a single unnamed value.
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

      # THE RECORD, IF THERE IS ONE. A record that does not exist yet is not
      # an error here — the ask still goes, carrying only its arguments, and
      # whatever the adapter makes of that is its own business. Refusing
      # would put a second existence check behind the one `resolve_references`
      # already performed.
      def held_state(ctx)
        identity = ctx.operation.identity_attribute(ctx.aggregate.hecks_name) or return {}
        found    = @registry.repository(ctx.domain, ctx.aggregate).find(ctx.args[identity.name])
        found ? Value.materialize(found.state) : {}
      rescue StandardError
        {}
      end

      # THE PORT THIS OPERATION BELONGS TO, found by asking the aggregate
      # rather than threading it through the call — the dispatcher already
      # resolved it once to get here, and a second parameter carried purely so
      # this method can read it would be a parameter every OTHER step ignores.
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

      # A Value never crosses the boundary — an adapter is somebody else's
      # code and should be handed plain data, the same reasoning `JsonDoor`
      # gives for materialising before it hands anything to an HTTP caller.
      def materialise(args) = Value.materialize(args)

      def announce(ctx, event_name, payload)
        identity_attribute = ctx.operation.identity_attribute(ctx.aggregate.hecks_name)
        event = Event.new(
          name:        event_name,
          aggregate:   "#{ctx.domain}::#{ctx.aggregate.hecks_name}",
          id:          ctx.args[identity_attribute.name],
          payload:     payload,
          occurred_at: Time.now.utc.iso8601
        )
        @registry.event_log << event
        [event]
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
          @registry.event_log << event.emit!
          event
        end
      end
    end
  end
end
