require_relative "../../bluebook/expression/evaluator"
require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"
require_relative "../instance"

module Hecks
  module Runtime
    class CommandRules
      # Whether a command may run at all: its declared givens, and the
      # lifecycle transition it asks for.
      module Admissibility
        # Wraps `subject` so a guard reads a declared, optional attribute
        # that predates the record as nil instead of raising.
        class GuardState
          def initialize(instance)
            @instance = instance
            @declared = instance.respond_to?(:aggregate) ? instance.aggregate.attributes.to_h { |a| [a.name, a] } : {}
            # Separate index: a projected field's absence raises its own
            # refusal, not AttributeAbsent's (ADR 0025).
            owner = instance.aggregate if instance.respond_to?(:aggregate)
            @projected = owner.respond_to?(:projected_fields) ? owner.projected_fields.to_h { |f| [f.name, f] } : {}
          end

          def key?(name) = @declared.key?(name.to_sym) || @projected.key?(name.to_sym) || @instance.key?(name)

          # Nil for an absent optional attribute; raises for anything else absent.
          def [](name)
            return @instance[name] if @instance.key?(name)

            projected = @projected[name.to_sym]
            return raise_projection_absent(projected) if projected

            attribute = @declared[name.to_sym]
            return nil if attribute.nil? || attribute.optional?

            raise AttributeAbsent,
                  RefusalWording.render_site("AttributeAbsent", "absent_read",
                                             aggregate: @instance.aggregate.hecks_name, field: name)
          end

          private

          def raise_projection_absent(projected)
            raise ProjectionAbsent,
                  RefusalWording.render_site("ProjectionAbsent", "absent_read",
                                             aggregate: @instance.aggregate.hecks_name, field: projected.name,
                                             reference: projected.reference, remote_field: projected.remote_field)
          end
        end
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
        # @raise [Runtime::LifecycleRefused] `declaring`'s `from:` guard refuses
        #   the current lifecycle state
        def enforce_givens(subject, command, args, domain:, declaring: nil, parent: nil, correction: {})
          state = GuardState.new(subject)
          # A rule reads only within its own aggregate boundary (ADR 0025);
          # `dereference` below resolves fresh reference arguments only,
          # never a stored `projects` field, which `state` already has.
          attrs = args.merge(dereference(domain, command, args))
          attrs = attrs.merge(parent: parent.state) if parent
          attrs = attrs.merge(correction) unless correction.empty?
          command.givens.each do |given|
            next if Bluebook::Expression::Evaluator.call_rule(given, state, attrs)

            raise GivenNotMet.new(
              "#{command.hecks_name} refused — #{given.description}",
              detail: Bluebook::Expression::Evaluator.comparison_detail(given.canonical, state, attrs)
            )
          end

          enforce_lifecycle_guard(declaring, command, subject) if declaring
        end

        # Reads the durable event history a `corrects` mutation is judged
        # against (C9.2), falling back to the in-process log when needed.
        #
        # @param domain [String, Symbol] the domain `aggregate` belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate whose repository is read
        # @return [Array<Runtime::Event>] the aggregate's recorded events, or the
        #   registry's in-process log as a fallback
        def correction_history(domain, aggregate)
          @registry.repository(domain, aggregate).events || @registry.event_log
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
          bindings = {}
          command.mutations.each do |mutation|
            next unless mutation.op == :corrects

            event_key  = "#{domain}::#{aggregate.hecks_name}"
            event_name = mutation.target.to_s
            # Most recent match wins if this record emitted the same event
            # more than once.
            corrected = correction_history(domain, aggregate).reverse.find do |event|
              event.name == event_name && event.aggregate == event_key && event.id.to_s == instance.id.to_s
            end

            unless corrected
              raise NothingToCorrect,
                    "#{command.hecks_name} refused — corrects #{event_name}, but " \
                    "#{event_key} ##{instance.id} has never emitted it"
            end

            as = mutation.source[:as]
            bindings[as.to_sym] = corrected.payload if as && !as.to_s.empty?
          end
          bindings
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

          # Routed through the same "transition_blocked" template
          # `#admissible_transition` uses, so both raise identical wording.
          raise LifecycleRefused,
                RefusalWording.render_site("LifecycleRefused", "transition_blocked",
                                           command: command.hecks_name, field: lifecycle.field,
                                           current: Rendering.describe(current),
                                           allowed: Array(command.from))
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
        def enforce_ensures(subject, command, args, old:, domain:, parent: nil, correction: {})
          state = GuardState.new(subject)
          # Same aggregate-boundary rule as enforce_givens (ADR 0025) —
          # `state` already carries projected fields; only a fresh
          # reference-typed argument needs `dereference` here.
          attrs = args.reject { |name, _| subject.key?(name) }.merge(dereference(domain, command, args))
          attrs = attrs.merge(parent: parent.state) if parent
          attrs = attrs.merge(correction) unless correction.empty?
          attrs = attrs.merge(old: old)
          command.ensures.each do |rule|
            next if Bluebook::Expression::Evaluator.call_rule(rule, state, attrs)

            raise EnsuresNotMet, "#{command.hecks_name} refused — #{rule.description}"
          end
        end

        # Checks `aggregate`'s declared invariants against the settled
        # `subject`, then each of its entities' own invariants.
        #
        # No `dereference` here (ADR 0025) — an invariant may only read
        # `subject`'s own boundary, same rule enforce_givens/ensures hold to.
        #
        # @param subject [Runtime::Instance] the settled aggregate record checked
        # @param aggregate [Bluebook::Aggregate] the aggregate whose invariants are checked
        # @param domain [String, Symbol] domain `aggregate` belongs to
        # @return [void]
        # @raise [Runtime::InvariantViolation] a declared invariant does not hold, on
        #   `aggregate` itself or any of its entities
        def enforce_invariants(subject, aggregate, domain:)
          state = GuardState.new(subject)
          attrs = {}
          aggregate.invariants.each do |invariant|
            next if Bluebook::Expression::Evaluator.call_rule(invariant, state, attrs)

            raise InvariantViolation, "#{aggregate.hecks_name} refused — #{invariant.description}"
          end

          check_entity_invariants(aggregate, subject, domain: domain)
        end

        # Checks each of `owner_construct`'s entity types' own invariants
        # against every instance it holds, recursing into nested entities.
        #
        # An entity with no matching list attribute on its owner is skipped,
        # not raised — a static-analysis gap, not a runtime concern here.
        #
        # @param owner_construct [Bluebook::Aggregate, Bluebook::Entity] whose entities are checked
        # @param owner_instance [Runtime::Instance] settled record holding the entity lists
        # @param domain [String, Symbol] the domain `owner_construct` belongs to
        # @return [void]
        # @raise [Runtime::InvariantViolation] an entity invariant does not hold
        def check_entity_invariants(owner_construct, owner_instance, domain:)
          owner_construct.entities.each do |entity|
            next if entity.invariants.empty?

            list_attr = owner_construct.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name }
            next unless list_attr

            Array(owner_instance[list_attr.name]).each do |element|
              wrapped = Instance.new(aggregate: entity, id: nil, state: element)
              element_state = GuardState.new(wrapped)
              # No `dereference` (ADR 0025) — same boundary rule as
              # enforce_invariants above; `parent` (the owner's own
              # state, projected fields included) stays readable.
              attrs = { parent: owner_instance.state }

              entity.invariants.each do |invariant|
                next if Bluebook::Expression::Evaluator.call_rule(invariant, element_state, attrs)

                raise InvariantViolation, "#{entity.hecks_name} refused — #{invariant.description}"
              end

              check_entity_invariants(entity, wrapped, domain: domain)
            end
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

          # `Value.scalar` unwraps a VO-typed lifecycle field before `.to_s`;
          # without it, a wrapped field never matches any `from:` state.
          current  = Value.scalar(subject[lifecycle.field]).to_s
          admitted = candidates.find { |t| !t.constrained? || Array(t.from).include?(current) }
          return admitted if admitted

          allowed = candidates.flat_map { |t| Array(t.from) }.uniq
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
