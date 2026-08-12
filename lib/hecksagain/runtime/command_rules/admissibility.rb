require_relative "../../bluebook/expression/evaluator"
require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"

module Hecksagain
  module Runtime
    class CommandRules
      # Whether a command may run at all: its declared givens, and the
      # lifecycle transition it asks for.
      module Admissibility
        # WRAPS `subject` so a guard can read a DECLARED-but-storage-absent
        # optional attribute as nil, not "cannot resolve." `Instance
        # #hydrate_with_defaults` deliberately leaves one absent rather
        # than nil-filled — "an attribute with no default stays absent,
        # exactly as stored," that file's own comment — which is right
        # for storage fidelity but wrong for a `given`/`ensures` reading
        # an optional field a record predates (measured, not assumed: a
        # real Item.Promote crashed on `!promoted` against a record from
        # before `promoted` existed). Defensive on purpose — a `subject`
        # with no `.aggregate` (an entity's own view/settled wrapper,
        # entity_interpreter.rb's own callers) just degrades to today's
        # exact behavior, zero risk to a path this bug was never measured
        # against.
        class GuardState
          def initialize(instance)
            @instance = instance
            @declared = instance.respond_to?(:aggregate) ? instance.aggregate.attributes.map(&:name) : []
          end

          def key?(name) = @declared.include?(name.to_sym) || @instance.key?(name)
          def [](name) = @instance[name]
        end
        private_constant :GuardState

        def enforce_givens(subject, command, args)
          state = GuardState.new(subject)
          command.givens.each do |given|
            next if Bluebook::Expression::Evaluator.call(given.canonical, state, args)

            raise GivenNotMet, "#{command.hecks_name} refused — #{given.description}"
          end
        end

        # The far side of the contract: evaluated against the SETTLED record
        # — after mutations and the lifecycle move, before anything persists
        # — with `old` carrying the state as the givens saw it. Injected into
        # the attrs at evaluation time only; the payload gate never sees it.
        #
        # `old` — and every dispatch ARGUMENT — wins over a same-named STATE
        # field in expression scope (Resolver#fetch checks attrs first). An
        # ensures naming a field the command also takes as an argument (or,
        # on an entity, a field that doubles as the addressing argument
        # element_of reads) will read the ARGUMENT, not the settled value.
        # Not new to ensures — `given` lives under the same rule — but an
        # ensures is more likely to collide, since it typically re-reads a
        # field the command just took in to mutate it.
        def enforce_ensures(subject, command, args, old:)
          state = GuardState.new(subject)
          command.ensures.each do |rule|
            next if Bluebook::Expression::Evaluator.call(rule.canonical, state, args.merge(old: old))

            raise EnsuresNotMet, "#{command.hecks_name} refused — #{rule.description}"
          end
        end

        def admissible_transition(declaring, command, subject)
          lifecycle = declaring.lifecycle
          return nil unless lifecycle

          candidates = lifecycle.transitions_for(command.hecks_name)
          return nil if candidates.empty?

          # `Value.scalar` unwrap -- vendored addition, not (yet)
          # upstream hecksagain (migration plan task 9): a VO-typed
          # lifecycle field (the norm, not the exception, per this
          # corpus's own no-primitive-envy convention) holds a real
          # `Runtime::Value` here, and a bare `.to_s` on that hit Ruby's
          # default `Object#to_s` instead of unwrapping the inner
          # scalar first -- `current` came back as a raw object-pointer
          # string (`"#<Hecksagain::Runtime::Value:0x...>"`) that could
          # never match any declared `from` state, so EVERY transition
          # on a VO-typed lifecycle field refused unconditionally, and
          # when it refused the message leaked the pointer too.
          # Confirmed live via `Plan::Task.Complete` (status defaults to
          # `TaskStatus`, a single-field VO), not inferred. Reuses
          # `Value.scalar` -- this file's own third candidate for "how
          # to unwrap a Value/Hash-shaped field," already built and
          # already documented for exactly this job ("rendering a value
          # object into a column or a message, where there is no path
          # to consult," `value/coercion.rb`'s own comment) -- rather
          # than inventing a second unwrap helper beside `Resolver#
          # unwrap_scalar`'s bare-comparison one. Duck-typed the same
          # way : a bare, non-VO lifecycle field passes through
          # unchanged (`Value.scalar` only opens a `Value` instance).
          current  = Value.scalar(subject[lifecycle.field]).to_s
          admitted = candidates.find { |t| !t.constrained? || Array(t.from).include?(current) }
          return admitted if admitted

          allowed = candidates.flat_map { |t| Array(t.from) }.uniq
          raise LifecycleRefused,
                RefusalWording.render("LifecycleRefused", "transition_blocked",
                                      command: command.hecks_name, field: lifecycle.field,
                                      current: Rendering.describe(current),
                                      allowed: allowed.map(&:inspect).join(" or "))
        end
      end
    end
  end
end
