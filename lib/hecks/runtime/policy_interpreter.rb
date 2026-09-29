require_relative "../naming"
require_relative "errors"
require_relative "query_interpreter"
require_relative "reaction_invocation"
require_relative "refusal_wording"
require_relative "value"
require_relative "../bluebook/expression/evaluator"

module Hecks
  module Runtime
    # Fires the declared `policy` reactions triggered by one just-emitted event,
    # recording every outcome on the reaction log.
    class PolicyInterpreter
      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry whose loaded
      #   bluebooks are scanned for candidate policies
      # @param door [Runtime::Dispatcher] the dispatcher reactions re-enter through,
      #   and whose reaction-depth guard is checked before each delivery
      def initialize(registry, door:)
        @registry = registry
        @door     = door
      end

      # Fires every declared policy `event` triggers, recording each outcome on
      # the registry's reaction log. A policy whose `where` does not hold logs nothing.
      #
      # @param event [Runtime::Event] the just-emitted event to react to
      # @param domain [String, Symbol] the domain `event`'s own aggregate belongs
      #   to, the emitting domain's policies fire first
      # @param only [Array(Bluebook::Policy, String), nil] one `[policy, home_domain]`
      #   pair to run exactly (the outbox relay's consumer), instead of scanning every
      #   loaded bluebook for candidates
      # @return [void]
      def react(event, domain, only: nil)
        selected = only ? [only] : policies_for(event, domain)
        selected.each do |policy, home_domain|
          result = deliver(policy, event, home_domain)
          next if result.nil?

          # A for_each policy answers an array; Array(...) would explode a record Hash.
          (result.is_a?(Array) ? result : [result]).each { |record| @registry.log_reaction(record) }
        end
      end

      private

      # Scans every loaded bluebook, since a policy commonly lives in a different
      # domain than the event it reacts to. Returns [policy, home_domain] pairs: the
      # home domain is the fallback for a bare trigger or for_each route. Order is the
      # emitting domain first, then load order, matching Outbox::Fanout and the Rust kernel.
      def policies_for(event, domain)
        emitting = Naming.demodulise(event.aggregate)

        Outbox.bluebooks_home_first(@registry, domain).flat_map do |bluebook|
          matching = bluebook.policies.select do |policy|
            policy.event_name == event.name &&
              (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
          end
          matching.map { |policy| [policy, bluebook.name] }
        end
      end

      # Evaluated against the event payload alone (a policy has no aggregate state).
      # Not rescued here: an EvaluationError must reach `deliver`'s defect rescue, not
      # read as a policy that declined to fire.
      def where_holds?(policy, event)
        return true if policy.where.to_s.empty?

        Bluebook::Expression::Evaluator.call_rule(policy.where_rule, {}, event.payload.transform_keys(&:to_sym))
      end

      def deliver(policy, event, domain)
        # `record` must exist before anything can raise: both rescues call `.merge` on it.
        target = "#{policy.target_domain || domain}::#{policy.trigger_command}"
        record = { policy: policy.name, on: event.name, trigger: target }

        return deliver_for_each(policy, event, domain, target, record) unless policy.for_each.to_s.empty?
        return nil unless where_holds?(policy, event)

        if @door.reaction_depth_reached?
          return record.merge(delivered: false,
                              reason:    "reaction depth #{@door.max_reaction_depth} reached")
        end

        args = trigger_args(policy, event)
        @door.reenter(target, **reaction_invocation(target, args, policy, event))
        record.merge(delivered: true)
      rescue *DOMAIN_REFUSALS => e
        record.merge(delivered: false, reason: e.message)
      rescue StandardError => e
        # A defect, not a refusal: recorded with `defect: true` and warned, never
        # re-raised. The emitting command has already persisted, so propagating would
        # only fail an unrelated caller. See DOMAIN_REFUSALS for why the two stay apart.
        warn "[hecks] defect in reaction — policy #{policy.name} on #{event.name} " \
             "firing #{target}: #{e.class}: #{e.message}"
        record.merge(delivered: false, reason: e.message, defect: true, error_class: e.class.name)
      end

      # Runs the `for_each` query against the event payload and fires the trigger once
      # per row, addressing each row by `addressing_key_for`. A refusal is recorded per
      # row and the fan-out continues; a crash resolving the query or an unaddressable
      # target is one top-level defect for the policy.
      def deliver_for_each(policy, event, domain, target, record)
        return nil unless where_holds?(policy, event)

        query_domain, aggregate_name, query_name = policy.for_each_route(domain)
        aggregate = resolve_query_aggregate(query_domain, aggregate_name, policy.for_each)
        # The query reads the event, never the `with:` projection: it asks which rows.
        query_args    = for_each_query_args(aggregate.query(query_name), event)
        rows          = QueryInterpreter.new(@registry).call(query_domain, aggregate, query_name, query_args)
        reference_key = addressing_key_for(target, aggregate_name)

        Array(rows).map do |row|
          deliver_for_each_row(target, record, trigger_args(policy, event, reference_key => row[:id]), row, policy, event)
        end
      rescue *DOMAIN_REFUSALS => e
        record.merge(delivered: false, reason: e.message)
      rescue StandardError => e
        warn "[hecks] defect in reaction — policy #{policy.name} on #{event.name} " \
             "resolving for_each #{policy.for_each}: #{e.class}: #{e.message}"
        record.merge(delivered: false, reason: e.message, defect: true, error_class: e.class.name)
      end

      # The event's own identity is not in its payload, so a query argument named
      # after an identity head of the emitting aggregate is filled from `event.id`.
      # Without it the query silently sees nothing. Never overrides a payload value.
      def for_each_query_args(query, event)
        args = event.payload.transform_keys(&:to_sym)
        return args unless query

        domain, bare_name = event.aggregate.to_s.split("::", 2)
        construct = bare_name && @registry.bluebook(domain)&.aggregate(bare_name)
        return args unless construct

        heads = construct.identity_heads.map(&:to_s)
        query.attributes.each do |attribute|
          next if args.key?(attribute.name)
          next unless heads.include?(attribute.name.to_s)

          args[attribute.name] = event.id
        end
        args
      end

      # What the trigger is given: the whole event payload verbatim when no `with:` is
      # declared, otherwise the projection (a Symbol names a payload field, anything else
      # is a literal). `extra` is a fan-out's row key, merged into the source before the
      # projection so a `with:` can name the row it acts on.
      def trigger_args(policy, event, extra = {})
        payload = event.payload.transform_keys(&:to_sym).merge(extra)
        return payload unless ReactionInvocation.projection_declared?(policy)

        payload = emitter_identity(event).merge(payload)

        args = ReactionInvocation.resolve_mapping(
          with_spec: policy.with_spec,
          scopes:    [["event payload and fan-out row", payload]],
          label:     "#{policy.name}'s trigger"
        )

        # Raw inputs kept for Properties.dispatch_binding_fidelity's re-derivation.
        @registry.policy_dispatch_log << { policy: policy.name, on: event.name, payload: payload,
                                            with_spec: policy.with_spec, args: args }
        args
      end

      # The emitting record's identity, offered to an explicit `with:` projection under
      # the emitting aggregate's identity heads (never over a payload value). Without it
      # a cross-aggregate reaction cannot say which record to address. The build-time
      # validator admits the same names (`BluebookBuilder.check_with_spec!`).
      def emitter_identity(event)
        return {} if event.id.nil? || event.id.to_s.empty?

        domain, bare_name = event.aggregate.to_s.split("::", 2)
        construct = bare_name && @registry.bluebook(domain)&.aggregate(bare_name)
        return {} unless construct

        construct.identity_heads.to_h { |head| [head.to_sym, event.id] }
      end

      # Resolves `target` back to its declared command and asks it how a row of
      # `aggregate_name` addresses it. Raises rather than guessing when the command is
      # unresolvable or cannot be addressed: a domain-authoring mistake to surface.
      def addressing_key_for(target, aggregate_name)
        target_domain, target_aggregate_name, target_command_name = Naming.split_verb(target)
        command = @registry.bluebook(target_domain)&.aggregate(target_aggregate_name)&.command(target_command_name)
        raise UnknownVerb, "for_each's own trigger #{target.inspect} does not resolve to a declared command" unless command

        key = command.addressing_key_for(aggregate_name)
        return key if key

        raise ArgumentError,
              "#{target} cannot be addressed by a row of #{aggregate_name} — it declares no self-reference to " \
              "#{aggregate_name} and no reference-typed attribute targeting it"
      end

      def deliver_for_each_row(target, record, args, row, policy, event)
        row_record = record.merge(for_row: row[:id])

        if @door.reaction_depth_reached?
          return row_record.merge(delivered: false,
                                  reason:    "reaction depth #{@door.max_reaction_depth} reached")
        end

        # The row key is already merged by `trigger_args`, so a projection can name it.
        @door.reenter(target, **reaction_invocation(target, args, policy, event))
        row_record.merge(delivered: true)
      rescue *DOMAIN_REFUSALS => e
        row_record.merge(delivered: false, reason: e.message)
      end

      def reaction_invocation(target, args, policy, event)
        ReactionInvocation.build(
          registry:        @registry,
          verb:            target,
          projected:       args,
          explicit:        ReactionInvocation.projection_declared?(policy),
          source_receiver: { aggregate: event.aggregate, identity: event.id }
        )
      end

      def resolve_query_aggregate(domain, aggregate_name, verb)
        bluebook = @registry.bluebook(domain) ||
                   raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_domain", domain: domain, verb: verb))
        bluebook.aggregate(aggregate_name) ||
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_aggregate",
                                                        domain: domain, aggregate: aggregate_name))
      end
    end
  end
end
