require_relative "../naming"
require_relative "errors"
require_relative "query_interpreter"
require_relative "refusal_wording"
require_relative "value"
require_relative "../bluebook/expression/evaluator"


module Hecksagain
  module Runtime
    class PolicyInterpreter
      attr_reader :registry

      def initialize(registry, door:)
        @registry = registry
        @door     = door
      end

      # `deliver` returns `nil` for a policy whose `where` did not hold —
      # SILENTLY, the same as a policy `policies_for` never selected at all
      # (an `event_qualifier` miss carries no reaction_log entry either) —
      # so nothing is appended for it. A `for_each` policy answers an ARRAY
      # (one record per matched row) rather than one record ; `Array(...)`
      # is wrong here (it would explode a plain record Hash into its own
      # key/value pairs), so the two shapes are told apart explicitly.
      def react(event, domain)
        policies_for(event, domain).each do |policy|
          result = deliver(policy, event, domain)
          next if result.nil?

          (result.is_a?(Array) ? result : [result]).each { |record| @registry.reaction_log << record }
        end
      end

      private

      def policies_for(event, domain)
        bluebook = @registry.bluebook(domain)
        return [] unless bluebook

        emitting = Naming.demodulise(event.aggregate)

        bluebook.policies.select do |policy|
          policy.event_name == event.name &&
            (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
        end
      end

      # THE GUARD, evaluated against the triggering event's own payload —
      # a policy has no aggregate instance of its own to read state from,
      # so `state` is empty and every bare name a `where` resolves comes
      # from `attrs` (Expression::Resolver#fetch checks `attrs` before
      # `state`, so this is exactly the shape `enforce_givens` already
      # gives a command's own given, minus the settled-record half a
      # policy simply has none of). Called from inside `deliver`'s own
      # rescue-guarded body (both callers, below) — never guarded here —
      # so an EvaluationError (an unresolvable field, a bad comparison) is
      # caught the SAME way any other reaction defect is, not swallowed as
      # though the policy had merely declined to fire.
      def where_holds?(policy, event)
        return true if policy.where.to_s.empty?

        Bluebook::Expression::Evaluator.call(policy.where, {}, event.payload.transform_keys(&:to_sym))
      end

      def deliver(policy, event, domain)
        # `record` ASSIGNED BEFORE ANY BRANCH THAT CAN RAISE, same reason
        # `deliver_for_each`'s own header gives : both rescue clauses below
        # call `.merge` on it, and a defect raised before it existed would
        # be caught here only to raise a second, different NoMethodError
        # trying to record the first one.
        target = "#{policy.target_domain || domain}::#{policy.trigger_command}"
        record = { policy: policy.name, on: event.name, trigger: target }

        return deliver_for_each(policy, event, domain, target, record) unless policy.for_each.to_s.empty?
        return nil unless where_holds?(policy, event)

        if @door.reaction_depth_reached?
          return record.merge(delivered: false,
                              reason: "reaction depth #{@door.max_reaction_depth} reached")
        end

        @door.reenter(target, **trigger_args(policy, event))
        record.merge(delivered: true)
      rescue *DOMAIN_REFUSALS => error
        # The target refused — a fact about the domain, recorded and not
        # fatal to the command that emitted the event.
        record.merge(delivered: false, reason: error.message)
      rescue StandardError => error
        # A DEFECT, not a refusal — a NoMethodError in an interpreter, a
        # NameError from a missing constant, a TypeError from a bad
        # assumption : exactly the class of thing DOMAIN_REFUSALS
        # (errors.rb, see the comment above that constant) deliberately
        # excludes, and for the reason that comment gives at length —
        # folding a crash into the same `delivered: false` shape as an
        # ordinary refusal makes a broken runtime read as normal operation
        # in the log. This clause does not reopen that hole: it is a
        # SECOND, narrower rescue, tried only once the first one above has
        # already declined to match, so a legitimate refusal still takes
        # the branch above and a defect always takes this one.
        #
        # Catching it HERE is safe for a fact this method's caller cannot
        # see from where it sits: by the time `react` runs, the command
        # that EMITTED `event` has already succeeded and PERSISTED —
        # `Dispatcher#dispatch` calls `@policies.react` only after its own
        # `announced` events are already in hand. Letting this exception
        # keep propagating would not undo that command (nothing here is
        # transactional across aggregates) — it would only blow up the
        # ORIGINAL caller's `dispatch` call for a failure that happened in
        # a DIFFERENT command, one the caller never asked to run and has no
        # way to compensate for. So the defect is recorded, distinguishably
        # (`defect: true`, plus the error's own class — nothing here is
        # allowed to read like an ordinary refusal), warned to STDERR so it
        # is never silent, and left exactly where it happened for a human
        # to find — never re-raised, and never swallowed either.
        warn "[hecksagain] defect in reaction — policy #{policy.name} on #{event.name} " \
             "firing #{target}: #{error.class}: #{error.message}"
        record.merge(delivered: false, reason: error.message, defect: true, error_class: error.class.name)
      end

      # THE FAN-OUT — `policy.for_each` names a query ; this runs it
      # against the triggering event's own payload (the same source
      # `deliver`'s own ordinary path forwards to `trigger` wholesale) and
      # fires `trigger` once per row, merging each row's own id into the
      # forwarded payload under whichever name the TRIGGER addresses by —
      # `account:` when it acts on the fanned aggregate, `account_id:`
      # when it merely stores a reference to it. `reference_key_for`'s own
      # comment carries the difference and why writing one of them
      # unconditionally was wrong. A refusal is recorded per row and the
      # fan-out continues ;
      # a crash resolving the QUERY ITSELF (an unresolvable domain/
      # aggregate/query, or the evaluator raising) is a single top-level
      # defect for the policy, the same shape `deliver`'s own outer rescue
      # already gives every other reaction.
      def deliver_for_each(policy, event, domain, target, record)
        return nil unless where_holds?(policy, event)

        query_domain, aggregate_name, query_name = for_each_route(policy, domain)
        aggregate = resolve_query_aggregate(query_domain, aggregate_name, policy.for_each)
        # THE QUERY reads the EVENT, not the projection — `with:` says
        # what the TRIGGER is given, and a fan-out's query is asking a
        # different question (which rows) with the event's own vocabulary.
        # THE QUERY reads the EVENT, never the projection — `with:` says
        # what the TRIGGER is given, and the fan-out's query is asking a
        # different question (WHICH rows) in the event's own vocabulary.
        query_args    = event.payload.transform_keys(&:to_sym)
        rows          = QueryInterpreter.new(@registry).call(query_domain, aggregate, query_name, query_args)
        reference_key = reference_key_for("#{query_domain}::#{aggregate_name}", target)

        Array(rows).map do |row|
          args = trigger_args(policy, event, reference_key => row[:id])
          deliver_for_each_row(target, record, args, row)
        end
      rescue *DOMAIN_REFUSALS => error
        record.merge(delivered: false, reason: error.message)
      rescue StandardError => error
        warn "[hecksagain] defect in reaction — policy #{policy.name} on #{event.name} " \
             "resolving for_each #{policy.for_each}: #{error.class}: #{error.message}"
        record.merge(delivered: false, reason: error.message, defect: true, error_class: error.class.name)
      end

      def deliver_for_each_row(target, record, args, row)
        row_record = record.merge(for_row: row[:id])

        if @door.reaction_depth_reached?
          return row_record.merge(delivered: false,
                                  reason: "reaction depth #{@door.max_reaction_depth} reached")
        end

        # ALREADY MERGED, by `trigger_args` — the row key has to be in the
        # source a `with:` projection reads from, not bolted on after it,
        # or a projection could never name the row it acts on.
        @door.reenter(target, **args)
        row_record.merge(delivered: true)
      rescue *DOMAIN_REFUSALS => error
        row_record.merge(delivered: false, reason: error.message)
      end

      # `for_each "Account.OpenForCustomer"` runs against THIS EVENT'S OWN
      # domain by default — the same default a saga's own `dispatch`
      # command name takes (`SagaInterpreter#qualified`) — or an explicit
      # `"Domain::Aggregate.query_name"` names its own. Deliberately
      # independent of `across`/`target_domain`, which name where
      # `trigger` fires, not where the fan-out's own query runs — the two
      # need not be the same domain.
      def for_each_route(policy, domain)
        path, query_name = policy.for_each.to_s.split(".", 2)
        query_domain, aggregate_name = path.to_s.include?("::") ? path.split("::", 2) : [domain, path]

        [query_domain, aggregate_name, query_name]
      end

      # THE SAME MINT `AggregateBuilder#reference_to` gives a bare
      # `reference_to Account` (`account_id`, no `as:`) — `Naming
      # .reference_key` plus the `_id` suffix, the same two-step
      # `Interview::Source#default` already uses for exactly this reason —
      # so a `for_each` iterating Account and a command written
      # `reference_to Account` agree on the argument's name without either
      # one having to say so twice.
      # THE ROW'S ID, UNDER THE NAME THE TRIGGER ACTUALLY ADDRESSES BY.
      # Two different names are correct here, and which one depends on
      # whether the rows being fanned over ARE the records the trigger
      # acts on :
      #
      #   for_each "Account.OpenForCustomer" + trigger "Account.Freeze"
      #     -> `account:`    — Freeze ACTS ON that account. A command
      #                        referencing its OWN aggregate is addressed
      #                        by the bare reference key (see
      #                        `ArgumentGate#reference_key`, which is the
      #                        rule this now matches) and declares no
      #                        attribute for it at all.
      #
      #   for_each "Account.OpenForCustomer" + trigger "Alert.Raise"
      #     -> `account_id:` — the account is a FOREIGN reference the
      #                        target stores as an attribute, which is
      #                        what `reference_to` mints on an aggregate.
      #
      # Written `_id` unconditionally before, which is only ever right for
      # the second shape — so the first, which is what a fan-out IS in
      # practice (iterate one aggregate's rows, fire that same aggregate's
      # command), was refused with `UnknownArgument` naming a key the
      # command could not have taken. The fan-out itself was correct : the
      # right rows, the right ids, `where` gating properly, one recorded
      # `for_row:` each. Only the name they arrived under was wrong, so it
      # failed as a per-row refusal in the reaction log rather than
      # anywhere a caller would see it.
      # WHAT THE TRIGGER IS GIVEN. Undeclared, the event's whole payload
      # forwards verbatim — the behaviour every policy had before the
      # word existed, and still the right default for a trigger shaped
      # like its event.
      #
      # Declared, it is the same reading a saga's own `dispatch ...,
      # with:` gets (`SagaInterpreter#dispatch_args`): a Symbol names a
      # field on the SOURCE below, anything else is a literal the policy
      # supplies itself. A saga additionally resolves against its own
      # memory and correlation key; a policy has neither — it holds
      # nothing between events — so the source is the event, plus:
      #
      # `extra` is a FAN-OUT'S ROW KEY, merged into the source BEFORE the
      # projection rather than after it. That is what lets a `for_each`
      # policy name the row it is acting on — `with: { account: :account }`
      # — and therefore what lets one send the row and NOTHING ELSE. A
      # trigger that needs only which record to act on is the ordinary
      # case for a fan-out, and before this it could not be written: the
      # whole event rode along, and the target had to declare every field
      # of it whether it read them or not.
      def trigger_args(policy, event, extra = {})
        payload = event.payload.transform_keys(&:to_sym).merge(extra)
        return payload if policy.with_spec.to_a.empty?

        policy.with_spec.to_h do |key, value|
          resolved = value.is_a?(Symbol) ? payload[value] : value
          # Carried as STATE, not as the emitting aggregate's own runtime
          # type — the same reason a saga materialises: two aggregates may
          # share a value object's fields without sharing the class.
          [key.to_sym, Value.materialize(resolved)]
        end
      end

      def reference_key_for(aggregate_fqn, target)
        key = Naming.reference_key(aggregate_fqn)
        acts_on_rows?(aggregate_fqn, target) ? key : :"#{key}_id"
      end

      # `target` is "Domain::Aggregate.Command", built by `deliver` — so
      # the aggregate it acts on is everything left of the dot, compared
      # QUALIFIED rather than by bare name : a fan-out over one domain's
      # `Account` triggering another domain's same-named aggregate is a
      # foreign reference, not a self one.
      def acts_on_rows?(aggregate_fqn, target) = target.to_s.split(".").first == aggregate_fqn

      def resolve_query_aggregate(domain, aggregate_name, verb)
        bluebook = @registry.bluebook(domain) ||
                   raise(UnknownVerb, RefusalWording.render("UnknownVerb", "no_domain", domain: domain.inspect, verb: verb))
        bluebook.aggregate(aggregate_name) ||
          raise(UnknownVerb, RefusalWording.render("UnknownVerb", "no_aggregate",
                                                    domain: domain, aggregate: aggregate_name.inspect))
      end
    end
  end
end
