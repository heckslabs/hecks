require_relative "../../bluebook/expression/evaluator"
require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"
require_relative "../instance"
require_relative "guard_state"
require_relative "invariants"

module Hecks
  module Runtime
    class CommandRules
      # Whether a command may run at all: its declared givens, and the
      # lifecycle transition it asks for.
      module Admissibility
        include Invariants

        private_constant :GuardState

        # Checks whether `command` may run against `subject`: its declared
        # `given`s, then `declaring`'s lifecycle guard.
        #
        # @param subject [Runtime::Instance] pre-mutation record a `given` reads
        # @param declaring [Bluebook::Aggregate, Bluebook::Entity, nil] also runs
        #   the lifecycle guard when given
        # @param parent [Runtime::Instance, nil] entity command's parent record
        # @param correction [Hash{Symbol => Object}] `corrects` event bindings
        # @return [void]
        # @raise [Runtime::GivenNotMet] a declared `given` does not hold
        # @raise [Runtime::LifecycleRefused] `declaring`'s `from:` guard refuses the state
        # rubocop:disable-next Metrics/ParameterLists -- the dispatch context every interpreter passes by keyword
        def enforce_givens(subject, command, args, domain:, declaring: nil, parent: nil, correction: {})
          # A rule reads only within its own aggregate boundary (ADR 0025);
          # `dereference` below resolves fresh reference arguments only,
          # never a stored `projects` field, which `state` already has.
          attrs = with_rule_context(args.merge(dereference(domain, command, args)), parent, correction)
          refuse_unmet_givens(command, GuardState.new(subject), attrs)

          enforce_lifecycle_guard(declaring, command, subject) if declaring
        end

        # Reads the durable event history a `corrects` mutation is judged
        # against (C9.2), scoped to the one record being corrected so a
        # durable adapter need not load every aggregate's events to check
        # one; falls back to the in-process log when needed.
        #
        # @param domain [String, Symbol] the domain `aggregate` belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate whose repository is read
        # @param event_key [String] the `"domain::AggregateName"` key events are stored under
        # @param id [String, Object] the record's identity being corrected
        # @return [Array<Runtime::Event>] the record's recorded events, or the
        #   registry's in-process log as a fallback
        def correction_history(domain, aggregate, event_key, id)
          repository_events = @registry.repository(domain, aggregate).events_for(aggregate: event_key, id: id)
          return repository_events if repository_events

          # The in-process log holds every domain's events, so the fallback
          # scopes it the same way a durable adapter's own query would.
          @registry.event_log.select { |event| event.aggregate == event_key && event.id.to_s == id.to_s }
        end

        # Locates each `:corrects` mutation's already-emitted target event
        # and binds every `as:`-named one for `given`/`ensures` to reference.
        # Not an ordinary `given`: this is a log fact, raised structurally,
        # like NotFound/AlreadyExists.
        #
        # @param instance [Runtime::Instance] the record being corrected
        # @param aggregate [Bluebook::Aggregate] the aggregate `instance` belongs to
        # @param command [Class] the command whose `:corrects` mutations are located
        # @param domain [String, Symbol] the domain `aggregate` belongs to
        # @return [Hash{Symbol => Object}] payload per mutation's `as:` name; empty
        #   for a mutation with no `as:`
        # @raise [Runtime::NothingToCorrect] a named event `instance` never emitted
        def enforce_correction_target(instance, aggregate, command, domain:)
          corrections = command.mutations.select { |mutation| mutation.op == :corrects }
          corrections.each_with_object({}) do |mutation, bindings|
            corrected = corrected_event(instance, aggregate, command, mutation, domain)
            as = mutation.source[:as]
            bindings[as.to_sym] = corrected.payload if as && !as.to_s.empty?
          end
        end

        # Checks a command's own `from:` lifecycle guard — a precondition,
        # not a transition; `admissible_transition` below handles moves.
        #
        # @param declaring [Bluebook::Aggregate, Bluebook::Entity] construct whose
        #   lifecycle field is checked
        # @param command [Class] the command class whose `from:` guard is checked
        # @param subject [Runtime::Instance] pre-mutation record to read lifecycle off
        # @return [void]
        # @raise [Runtime::LifecycleRefused] `command` declares `from:` and current
        #   state isn't one of them
        def enforce_lifecycle_guard(declaring, command, subject)
          return unless command.from

          lifecycle = declaring.lifecycle
          current   = Value.scalar(subject[lifecycle.field]).to_s
          return if Array(command.from).include?(current)

          raise_transition_blocked(command, lifecycle, current, Array(command.from))
        end

        # Checks `command`'s declared `ensures` against `subject`, the settled
        # post-mutation record; `old` carries the pre-mutation state.
        # An argument sharing a settled field's name does not shadow it here.
        #
        # @param subject [Runtime::Instance] the settled, post-mutation record
        # @param old [Hash{Symbol => Object}, nil] pre-mutation state, readable as `old.*`
        # @param parent [Runtime::Instance, nil] entity command's parent record, if any
        # @param correction [Hash{Symbol => Object}] `corrects` event bindings, if any
        # @return [void]
        # @raise [Runtime::EnsuresNotMet] a declared `ensures` does not hold
        # rubocop:disable-next Metrics/ParameterLists -- the dispatch context every interpreter passes by keyword
        def enforce_ensures(subject, command, args, old:, domain:, parent: nil, correction: {})
          state = GuardState.new(subject)
          # Same aggregate-boundary rule as enforce_givens (ADR 0025) —
          # `state` already carries projected fields; only a fresh
          # reference-typed argument needs `dereference` here.
          fresh = args.reject { |name, _| subject.key?(name) }.merge(dereference(domain, command, args))
          attrs = with_rule_context(fresh, parent, correction).merge(old: old)
          command.ensures.each do |rule|
            next if Bluebook::Expression::Evaluator.call_rule(rule, state, attrs)

            raise EnsuresNotMet, "#{command.hecks_name} refused — #{rule.description}"
          end
        end

        # Finds the lifecycle transition `command` admits from `subject`'s
        # current state, if `declaring` declares a lifecycle and moves it.
        #
        # @param declaring [Bluebook::Aggregate, Bluebook::Entity] the construct with the lifecycle
        # @param command [Class] the command class to find a declared transition for
        # @param subject [Runtime::Instance] pre-mutation record read for current state
        # @return [Bluebook::StateTransition, nil] admitted transition, or nil when
        #   `declaring` has no lifecycle or `command` declares none
        # @raise [Runtime::LifecycleRefused] `command` declares transitions and none
        #   admits the record's current state
        def admissible_transition(declaring, command, subject)
          lifecycle = declaring.lifecycle
          return nil unless lifecycle

          candidates = lifecycle.transitions_for(command.hecks_name)
          return nil if candidates.empty?

          admitted_transition(candidates, command, lifecycle, subject)
        end

        private

        # Layers an entity command's parent state and a correction's bindings onto the attributes
        # a rule reads.
        def with_rule_context(attrs, parent, correction)
          attrs = attrs.merge(parent: parent.state) if parent
          attrs = attrs.merge(correction) unless correction.empty?
          attrs
        end

        def refuse_unmet_givens(command, state, attrs)
          command.givens.each do |given|
            next if Bluebook::Expression::Evaluator.call_rule(given, state, attrs)

            raise GivenNotMet.new(
              "#{command.hecks_name} refused — #{given.description}",
              detail: Bluebook::Expression::Evaluator.comparison_detail(given.canonical, state, attrs)
            )
          end
        end

        # The most recent emission of the event a `corrects` mutation names. Most recent match wins
        # if this record emitted the same event more than once; aggregate and id are already scoped
        # by correction_history, so only the event name is filtered here.
        def corrected_event(instance, aggregate, command, mutation, domain)
          event_key  = "#{domain}::#{aggregate.hecks_name}"
          event_name = mutation.target.to_s
          corrected  = correction_history(domain, aggregate, event_key, instance.id).reverse.find do |event|
            event.name == event_name
          end
          return corrected if corrected

          raise NothingToCorrect,
                "#{command.hecks_name} refused — corrects #{event_name}, but " \
                "#{event_key} ##{instance.id} has never emitted it"
        end

        # The candidate that admits the record's current state, or a refusal naming every state
        # the candidates would move from.
        def admitted_transition(candidates, command, lifecycle, subject)
          # `Value.scalar` unwraps a VO-typed lifecycle field before `.to_s`;
          # without it, a wrapped field never matches any `from:` state.
          current = Value.scalar(subject[lifecycle.field]).to_s
          candidates.find { |t| !t.constrained? || Array(t.from).include?(current) } ||
            raise_transition_blocked(command, lifecycle, current, candidates.flat_map { |t| Array(t.from) }.uniq)
        end

        # Routed through one "transition_blocked" template, so a lifecycle guard and a
        # transition raise identical wording.
        def raise_transition_blocked(command, lifecycle, current, allowed)
          raise LifecycleRefused,
                RefusalWording.render_site("LifecycleRefused", "transition_blocked",
                                           command: command.hecks_name, field: lifecycle.field,
                                           current: Rendering.describe(current),
                                           allowed: allowed)
        end
      end
    end
  end
end
