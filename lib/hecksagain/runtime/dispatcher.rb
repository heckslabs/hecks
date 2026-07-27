# Dispatcher — the door. Every command enters here, by fully-qualified verb.
#
#   dispatch("Pizzas::Pizza.Purchase", id: "pizza-1a2b", customer_name: "Chris")
#
# The sequence is fixed and entirely IR-driven — there is no handler body
# anywhere in this codebase:
#
#   1. resolve   — verb → bluebook → aggregate → command
#   2. hydrate   — load by id, or mint a fresh instance for a creating command
#   3. guard     — every `given` must hold, or the command is refused untouched
#   4. mutate    — creation attributes, then each `then_set`
#   5. persist   — save through the bound adapter
#   6. emit      — announce, only after the state is safely stored
#
# Emitting last is deliberate: an event is a promise that the state behind it
# survived.
require "securerandom"

module Hecksagain
  module Runtime
    class UnknownVerb < StandardError; end
    class GivenNotMet < StandardError; end
    class NotFound    < StandardError; end
    # A command moved against its declared state machine — a frozen account
    # frozen again, a settled transfer settled twice. The lifecycle block
    # parsed, validated, and gated NOTHING in either runtime until this
    # error had something to raise it.
    class LifecycleRefused < StandardError; end
    # A value arrived in a shape the domain does not admit — a scalar where a
    # multi-field value object was declared. Loud, because the alternative is
    # storing it raw and answering nil to every dotted read of it.
    class TypeMismatch < StandardError; end

    class Dispatcher
      # What a dispatch gives back: the instance as it now stands, and whatever
      # it announced.
      Result = Struct.new(:verb, :instance, :events, keyword_init: true) do
        def id    = instance.id
        def state = instance.to_h

        def to_s
          announced = events.empty? ? "no events" : events.map(&:name).join(", ")
          "#{verb} → #{instance.inspect} | #{announced}"
        end

        def inspect = "#<Result #{self}>"
      end

      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      # Every event emitted this session, oldest first.
      def events = @registry.event_log

      # Every policy that fired this session, and whether its command landed.
      def reactions = @registry.reaction_log

      # Every process-manager step this session — born, advanced, refused,
      # ended — oldest first.
      def sagas = @registry.saga_log
      def verbs  = @registry.verbs

      # THE QUESTIONS, finally answered. Seven queries in banking alone —
      # where / order_by / desc / limit / a caller-supplied :floor — parsed,
      # reached the IR, agreed byte-for-byte… and neither runtime could RUN
      # one. The fourth construct in the same silence (policies, sagas,
      # lifecycles before it). A query filters the store through the port,
      # orders, caps, and answers full records — id first, then state.
      def query(verb, **args)
        domain, aggregate_name, query_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)
        declared  = aggregate.queries.find { |q| q.name == query_name } ||
                    raise(UnknownVerb, "#{aggregate_name} has no query #{query_name.inspect}")

        records = @registry.repository(domain, aggregate).all
        matched = records.select { |r| declared.wheres.all? { |w| where_holds?(w, r, args) } }
        ordered = ordered(matched, declared.order_by)
        capped  = declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered

        capped.map { |r| { id: r.id }.merge(r.state) }
      end

      private

      # eq and lt are the whole vocabulary the DSL admits today. A clause
      # value is a literal, or a :symbol naming one of the query's own
      # attributes, resolved from the caller.
      def where_holds?(clause, record, args)
        held = record[clause.field]
        want = resolve_query_value(clause.value, args)

        case clause.op.to_s
        when "lt" then held.is_a?(Numeric) && want.is_a?(Numeric) && held < want
        else           held == want
        end
      end

      def resolve_query_value(value, args)
        value.is_a?(Symbol) ? args[value] : value
      end

      # Numeric fields sort as numbers, everything else as text, ties break
      # on id — spelled out because BOTH runtimes must sort identically or
      # the harness drowns in ordering noise that means nothing.
      def ordered(records, order_by)
        return records unless order_by

        field  = order_by.field
        sorted = records.sort_by do |r|
          value = r[field]
          value.is_a?(Numeric) ? [0, value, 0, r.id.to_s] : [1, 0, value.to_s, r.id.to_s]
        end
        order_by.direction.to_s == "desc" ? sorted.reverse : sorted
      end

      public

      def dispatch(verb, **args)
        domain, aggregate_name, command_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)
        command   = aggregate.command(command_name) ||
                    raise(UnknownVerb, "#{aggregate_name} has no command #{command_name.inspect}")

        repository = @registry.repository(domain, aggregate)
        instance   = hydrate(repository, aggregate, command, args)

        enforce_givens(instance, command, args)
        # The state machine gates BEFORE anything is written and moves AFTER
        # the mutations land — a refused Freeze touches nothing, and a legal
        # one changes state exactly once, beside the fields the command set.
        transition = admissible_transition(aggregate, command, instance)
        assign_creation_attributes(instance, aggregate, command, args) if command.creates?
        command.mutations.each { |mutation| apply(instance, aggregate, mutation, args) }
        instance[aggregate.lifecycle.field] = transition.target if transition

        repository.save(instance)
        announced = emit(command, domain, aggregate, instance, args, repository)

        # 7. REACT — a policy is a standing instruction that something else
        # should follow, so the reflex fires after the event it waits for.
        # After emit, for the same reason emit is last : a reaction is a
        # promise the state behind it survived.
        announced.each { |event| react_to(event, domain) }

        # 8. REMEMBER — a process manager is the conversation that outlives
        # any one command. After the reflexes, for the same reason again ;
        # and after react_to so a policy's reaction and a saga's advance
        # read the same event in a fixed order on both runtimes.
        announced.each { |event| advance_sagas(event, domain) }

        Result.new(verb: verb, instance: instance, events: announced)
      end

      private

      # The domain's reflex, finally connected. Four policies across the
      # corpus parsed, reached the IR, were agreed on byte-for-byte by both
      # parsers — and then fired nowhere, in either runtime. Parity was green
      # BECAUSE both discarded them equally : stage one cannot tell "both
      # understood it" from "both threw it away".
      #
      # EVERY reaction is recorded, delivered or not. A policy pointing at a
      # domain nobody loaded (pizzas' Notifications.Send) is a real thing to
      # know about, and swallowing it would rebuild the silence this fixes.
      def react_to(event, domain)
        # Depth rides an ivar rather than an argument because the nested call
        # goes back through the PUBLIC dispatch, which takes a verb and attrs
        # and nothing else. Threading it as a parameter would mean widening
        # the door for the benefit of one caller.
        depth = @reaction_depth.to_i

        policies_for(event, domain).each do |policy|
          @registry.reaction_log << deliver(policy, event, domain, depth)
        end
      end

      # A policy matches on the event NAME, and when its subscription is
      # qualified (`on "Order.Placed"`) on the emitting aggregate too. Both
      # helpers already existed on IR::Policy, unused — written for a
      # reaction that was never wired.
      def policies_for(event, domain)
        bluebook = @registry.bluebook(domain)
        return [] unless bluebook

        emitting = event.aggregate.to_s.split("::").last

        # DOMAIN-LEVEL ONLY. An aggregate-nested policy BUBBLES to the domain
        # at build time — the aggregate keeps a copy for its own IR, and
        # bluebook_builder says where the two agree : "the interpreter holds
        # them domain-level only". Reading both lists fired every nested
        # policy twice, which is what four reactions for two events looked
        # like before this comment was read.
        bluebook.policies.select do |policy|
          policy.event_name == event.name &&
            (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
        end
      end

      # THE REACTION HAS NO ARGUMENT MAPPING, and that is deliberate. Hecks's
      # policy builder carries `with` / `map` / `defaults` / `translate` ;
      # this one narrowed to on/trigger/across because, as its own comment
      # says, "a keyword that parses and then does nothing is worse than one
      # that is absent". So the event's payload is the only honest input, and
      # a reaction needing more than it carries CANNOT complete.
      #
      # That is recorded rather than raised. The triggering command already
      # succeeded and its state is saved ; a consequence that cannot be
      # delivered does not retract it. What it must not do is vanish.
      def deliver(policy, event, domain, depth)
        target = "#{policy.target_domain || domain}::#{policy.trigger_command}"
        record = { policy: policy.name, on: event.name, trigger: target }

        return record.merge(delivered: false, reason: "reaction depth #{MAX_REACTION_DEPTH} reached") if depth >= MAX_REACTION_DEPTH

        dispatch_reaction(target, event, domain, depth)
        record.merge(delivered: true)
      rescue StandardError => error
        record.merge(delivered: false, reason: error.message)
      end

      def dispatch_reaction(target, event, domain, depth)
        @reaction_depth = depth + 1
        dispatch(target, **event.payload.transform_keys(&:to_sym))
      ensure
        @reaction_depth = depth
      end

      # A policy whose command emits the event it waits for would react for
      # ever. Bounded rather than detected : the cycle is a modelling error,
      # and the runtime's job is to stop rather than to diagnose.
      MAX_REACTION_DEPTH = 5

      # ======================================================================
      # THE CONVERSATION THAT OUTLIVES A COMMAND — process managers, running.
      #
      # Settlement parsed, reached the IR, was agreed on byte-for-byte by both
      # parsers — and ran nowhere, in either runtime. The same silence the
      # policies had, one construct along. These four steps are the machine :
      #
      #   born      starts_on fires and the payload carries correlates_by —
      #             an instance is minted in the FIRST declared state, and it
      #             REMEMBERS the starting payload (a saga exists because
      #             something has to remember which half is done)
      #   advanced  a handler's event arrives carrying the correlation — the
      #             instance moves from→to FIRST, then the handler's
      #             dispatches fire (so a nested event sees the new state) ;
      #             `with:` symbols read the event payload first, the
      #             instance's memory second ; literals are themselves
      #   refused   a dispatch the domain turns away is RECORDED, delivered:
      #             false, and the saga does not pretend — the instance
      #             already moved ; what failed is on the log for the
      #             operator's queue (banking : InFlight, "the list that
      #             must always empty")
      #   ended     ends_on fires with the correlation — the instance retires
      #
      # An event that matches a handler but carries NO correlation value is
      # not saga traffic (a manual Debit is just a debit) ; one that carries
      # a correlation NOBODY remembers, or arrives in the wrong state, is
      # recorded — a conversation out of order is a fact worth keeping.
      # ======================================================================
      def advance_sagas(event, domain)
        bluebook = @registry.bluebook(domain)
        return unless bluebook

        bluebook.process_managers.each do |pm|
          begin_saga(pm, event)
          advance_saga(pm, event, domain)
          end_saga(pm, event)
        end
      end

      # The correlation value an event carries for one process manager :
      # the payload's correlates_by field when it rides there — and when the
      # field NAMES THE EMITTING AGGREGATE (correlates_by :transfer, event
      # from Transfer), the event's own id IS that value. `transfer` is the
      # reference-key spelling of a Transfer's identity everywhere else in
      # the language ; the saga reads it the same way, so TransferRequested
      # correlates without the domain smuggling its own id into a payload
      # field that repeats it.
      def saga_correlation(pm, event)
        value = event.payload[pm.correlates_by]
        return value unless value.to_s.empty?

        emitting = event.aggregate.to_s.split("::").last.to_s
        own_key  = emitting.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        own_key == pm.correlates_by.to_s ? event.id : nil
      end

      def begin_saga(pm, event)
        return unless event.name == pm.starts_on

        correlation = saga_correlation(pm, event)
        if correlation.to_s.empty?
          @registry.saga_log << { process_manager: pm.name, on: event.name,
                                  born: false, reason: "no #{pm.correlates_by} in the payload" }
          return
        end
        return if @registry.saga_instances[pm.name].key?(correlation)

        @registry.saga_instances[pm.name][correlation] =
          { state: pm.states.first, memory: event.payload }
        @registry.saga_log << { process_manager: pm.name, on: event.name,
                                instance: correlation, born: true, state: pm.states.first }
      end

      def advance_saga(pm, event, domain)
        handler = pm.handler_for(event.name)
        return unless handler

        correlation = saga_correlation(pm, event)
        return if correlation.to_s.empty?

        instance = @registry.saga_instances[pm.name][correlation]
        record   = { process_manager: pm.name, on: event.name, instance: correlation }

        unless instance
          @registry.saga_log << record.merge(advanced: false, reason: "no conversation remembers #{correlation.inspect}")
          return
        end
        unless instance[:state] == handler.from_state
          @registry.saga_log << record.merge(advanced: false,
                                             reason: "in #{instance[:state].inspect}, not #{handler.from_state.inspect}")
          return
        end

        instance[:state] = handler.to_state
        @registry.saga_log << record.merge(advanced: true, from: handler.from_state, to: handler.to_state)

        handler.dispatches.each do |spec|
          deliver_saga_dispatch(pm, spec, event, instance, correlation, domain)
        end
      end

      def deliver_saga_dispatch(pm, spec, event, instance, correlation, domain)
        # A `with:` symbol reads, in order : the conversation's own name when
        # it IS the correlates_by field (TransferRequested never carries a
        # `transfer` key — the transfer's id lives under `id` — yet inside
        # this saga `:transfer` means exactly the correlation), then the
        # triggering event's payload, then the remembered opening payload.
        args = spec.with_spec.to_h do |key, value|
          resolved = if !value.is_a?(Symbol) then value
                     elsif value == pm.correlates_by then correlation
                     elsif event.payload.key?(value) then event.payload[value]
                     else instance[:memory][value]
                     end
          [key.to_sym, resolved]
        end
        record = { process_manager: pm.name, instance: correlation, dispatch: spec.command_name }
        depth  = @reaction_depth.to_i

        if depth >= MAX_REACTION_DEPTH
          @registry.saga_log << record.merge(delivered: false, reason: "reaction depth #{MAX_REACTION_DEPTH} reached")
          return
        end

        begin
          @reaction_depth = depth + 1
          dispatch(qualified(spec.command_name, domain), **args)
          @registry.saga_log << record.merge(delivered: true)
        rescue StandardError => error
          @registry.saga_log << record.merge(delivered: false, reason: error.message)
        ensure
          @reaction_depth = depth
        end
      end

      # A saga dispatch written as "Banking::Account.Debit" is already
      # qualified ; "Account.Debit" belongs to the declaring domain.
      def qualified(command_name, domain)
        command_name.include?("::") ? command_name : "#{domain}::#{command_name}"
      end

      def end_saga(pm, event)
        return unless event.name == pm.ends_on

        correlation = saga_correlation(pm, event)
        return if correlation.to_s.empty?
        return unless @registry.saga_instances[pm.name].delete(correlation)

        @registry.saga_log << { process_manager: pm.name, on: event.name,
                                instance: correlation, ended: true }
      end

      # "Pizzas::Pizza.Purchase" => ["Pizzas", "Pizza", "Purchase"]
      def parse(verb)
        path, command = verb.to_s.split(".", 2)
        domain, aggregate = path.to_s.split("::", 2)

        unless domain && aggregate && command
          raise UnknownVerb, "#{verb.inspect} is not a fully-qualified verb (Domain::Aggregate.Command)"
        end

        [domain, aggregate, command]
      end

      def resolve_aggregate(domain, aggregate_name, verb)
        bluebook = @registry.bluebook(domain) ||
                   raise(UnknownVerb, "no domain #{domain.inspect} loaded (verb #{verb})")
        bluebook.aggregate(aggregate_name) ||
          raise(UnknownVerb, "#{domain} has no aggregate #{aggregate_name.inspect}")
      end

      # A creating command mints identity ; every other command loads by it.
      #
      # Three spellings address a record, in order : the natural key
      # (identified_by), the universal `id:`, and the REFERENCE KEY — the
      # snake_case of the aggregate a `reference_to` names, so `Reverse`
      # takes `transfer:` and `Suspend` takes `customer:`. Hecks locked this
      # convention long ago ; here only the first spelling ever resolved, so
      # every `transfer:`-addressed command in the corpus — the whole saga's
      # Debited/Settle/Reverse surface — refused with "pass id:", in both
      # runtimes, and 21 agreeing refusals looked like a passing suite.
      def hydrate(repository, aggregate, command, args)
        if command.creates?
          id = args[aggregate.identified_by] || mint_id(aggregate)
          Instance.new(aggregate: aggregate, id: id)
        else
          id = args[aggregate.identified_by] || args[:id] || args[reference_key(command)] ||
               raise(NotFound, "#{command.name} acts on an existing #{aggregate.name} — pass #{aggregate.identified_by}:")
          repository.find(id) || raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{id.inspect}")
        end
      end

      # `reference_to Transfer` means the caller may say `transfer:`.
      def reference_key(command)
        target = command.references.to_s
        return nil if target.empty?

        target.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.to_sym
      end

      def mint_id(aggregate)
        "#{aggregate.storage_name}-#{SecureRandom.hex(4)}"
      end

      # The lifecycle's admission rule. Nil when the command is not part of
      # the machine ; the admitted StateTransition when it is and the current
      # state allows it ; LifecycleRefused when the machine says no. A
      # transition with no `from:` admits any state. The helpers this walks
      # (transitions_for, constrained?) sat on IR::Lifecycle from the day it
      # was written, called by nothing — the same shelf IR::Policy's matchers
      # waited on.
      def admissible_transition(aggregate, command, instance)
        lifecycle = aggregate.lifecycle
        return nil unless lifecycle

        candidates = lifecycle.transitions_for(command.name)
        return nil if candidates.empty?

        current  = instance[lifecycle.field].to_s
        admitted = candidates.find { |t| !t.constrained? || Array(t.from).include?(current) }
        return admitted if admitted

        allowed = candidates.flat_map { |t| Array(t.from) }.uniq
        raise LifecycleRefused,
              "#{command.name} refused — #{lifecycle.field} is #{current.inspect}, and " \
              "#{command.name} moves it only from #{allowed.map(&:inspect).join(' or ')}"
      end

      # All givens must hold. A refused command leaves the instance untouched
      # because nothing has been written yet.
      def enforce_givens(instance, command, args)
        command.givens.each do |given|
          next if Bluebook::Expression::Evaluator.call(given.canonical, instance, args)

          raise GivenNotMet, "#{command.name} refused — #{given.description}"
        end
      end

      # On creation, a command attribute sharing a name with an aggregate
      # attribute lands on it. No then_set needed for the obvious case.
      def assign_creation_attributes(instance, aggregate, command, args)
        command.attributes.each do |attr|
          next unless aggregate.attribute(attr.name)
          next unless args.key?(attr.name)

          instance[attr.name] = coerce(aggregate, attr.name, args[attr.name])
        end
      end

      def apply(instance, aggregate, mutation, args)
        case mutation.op
        when :set
          value = resolve_source(mutation.source, args)
          instance[mutation.target] = coerce(aggregate, mutation.target, value)
        when :append
          instance[mutation.target] = appended(instance, aggregate, mutation, args)
        when :increment
          instance[mutation.target] = arithmetic(instance, mutation, args, 1)
        when :decrement
          instance[mutation.target] = arithmetic(instance, mutation, args, -1)
        end
      end

      # Integer cents or nothing. Money is the reason these ops exist, and
      # IEEE 754 has no place in a ledger — so a non-Integer amount is refused
      # LOUDLY rather than coerced. (Hecks's runtime falls back to ±1 when the
      # amount will not read as a number ; a balance moving by one cent because
      # the caller sent "lots" is exactly the silent wrongness this refuses.)
      def arithmetic(instance, mutation, args, sign)
        amount  = resolve_source(mutation.source, args)
        current = instance[mutation.target] || 0
        op      = sign.positive? ? "increment" : "decrement"

        unless amount.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{mutation.target} needs an Integer, got #{amount.inspect}"
        end
        unless current.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{mutation.target} needs an Integer #{mutation.target}, got #{current.inspect}"
        end

        current + (sign * amount)
      end

      # A VALUE-OBJECT-TYPED FIELD IS CONSTRUCTED, NOT STORED RAW.
      #
      # Value.build was only ever reached from the append path, so a scalar
      # attribute declared as a value object was assigned whatever arrived
      # and never validated. `amount: 2500` on an attribute typed Money sat
      # there as an Integer, and `amount.cents` — a dotted read into what the
      # domain says is a Money — walked into a non-Hash and answered nil.
      # Both runtimes did it, so parity was green over a value object that
      # never existed and an invariant that never fired.
      #
      # A SINGLE-ATTRIBUTE value object accepts a bare scalar, because
      # `kind: "current"` is unambiguous — there is exactly one field it
      # could mean, and making an author write `{ name: "current" }` buys
      # nothing. Anything richer must arrive as its fields, because guessing
      # which one of several a scalar meant is how a currency ends up in a
      # cents column.
      def coerce(aggregate, name, value)
        value_object = value_object_for(aggregate, name)
        return value unless value_object
        return value if value.nil?

        Value.build(value_object, fields_for(value_object, name, value))
      end

      # The value object a SCALAR attribute is declared as, or nil. A list
      # attribute is built element by element in `appended`, not here.
      def value_object_for(aggregate, name)
        attribute = aggregate.attribute(name)
        return nil unless attribute&.scalar?

        aggregate.value_object(attribute.type)
      end

      def fields_for(value_object, name, value)
        return value.transform_keys(&:to_sym) if value.is_a?(Hash)

        only = value_object.attributes
        if only.size == 1
          return { only.first.name => value }
        end

        raise TypeMismatch,
              "#{name} is a #{value_object.name}, which has " \
              "#{only.map { |a| a.name }.join(', ')} — pass those fields, not " \
              "#{value.inspect}. A scalar can only stand in for a value " \
              "object with exactly one field."
      end

      # A Symbol naming a command attribute reads that argument ; anything else
      # is a literal.
      def resolve_source(source, args)
        return args[source] if source.is_a?(Symbol) && args.key?(source)

        source
      end

      # An appended field is either an ARGUMENT to read or a LITERAL to write —
      # the same Symbol-vs-literal rule resolve_source applies to `to:`. This
      # read every field as an argument lookup, so a literal like
      # `direction: "credit"` looked up args["credit"], found nothing, and every
      # ledger entry in the corpus carried `direction: null` — in BOTH runtimes,
      # which is why parity never said a word.
      def appended(instance, aggregate, mutation, args)
        fields       = mutation.source.transform_values { |source| source.is_a?(Symbol) ? args[source] : source }
        element_type = aggregate.attribute(mutation.target)&.type
        value_object = aggregate.value_object(element_type)
        element      = value_object ? Value.build(value_object, fields) : fields

        Array(instance[mutation.target]) + [element]
      end

      def emit(command, domain, aggregate, instance, args, repository)
        command.emits.map do |event_name|
          event = Event.new(
            name:        event_name,
            aggregate:   "#{domain}::#{aggregate.name}",
            id:          instance.id,
            payload:     args,
            occurred_at: Time.now.utc.iso8601
          )
          @registry.event_log << event
          repository.record_event(event) if repository.respond_to?(:record_event)
          event
        end
      end
    end
  end
end
