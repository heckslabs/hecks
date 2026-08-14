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
        #
        # NIL IS NOT THE ONLY OUTCOME, though. The Item.Promote fix above
        # covered an OPTIONAL field — the honest case, where absence is
        # exactly what optional means. It also, as a side effect, let a
        # NON-optional field predating a record read nil the same way,
        # which is the `ne:`/array-`in:` bug class applied to rule
        # evaluation: a predicate silently answers against a value nobody
        # ever wrote (ADR 0025, "Added attributes and absence"). `[]`
        # below narrows the nil-read back to what it was built for —
        # optional stays nil, non-optional raises a named refusal
        # identifying the field, so a rule that reads it fails loud
        # instead of quietly wrong.
        class GuardState
          def initialize(instance)
            @instance = instance
            @declared = instance.respond_to?(:aggregate) ? instance.aggregate.attributes.to_h { |a| [a.name, a] } : {}
          end

          def key?(name) = @declared.key?(name.to_sym) || @instance.key?(name)

          def [](name)
            return @instance[name] if @instance.key?(name)

            attribute = @declared[name.to_sym]
            return nil if attribute.nil? || attribute.optional?

            raise AttributeAbsent,
                  RefusalWording.render("AttributeAbsent", "absent_read",
                                        aggregate: @instance.aggregate.hecks_name, field: name)
          end
        end
        private_constant :GuardState

        # `domain:` is only needed to dereference a reference-typed field
        # (`customer.status`) — see References#dereference. `owner` is the
        # declaring aggregate/entity when `subject` carries one (an
        # entity's pre-mutation `view` does, same as an aggregate's
        # `Instance`); a `subject` with no `.aggregate` just hydrates
        # nothing from state, same as GuardState degrades above.
        #
        # MERGE ORDER MATTERS, and it is NOT "args always win": an
        # unaliased command-level reference dereferences under a
        # different name than the argument holds (`account_id` the arg,
        # `account` the hydrated key — no collision, order is moot). An
        # ALIASED one (`reference_to Customer, as: :customer`) hydrates
        # under the SAME name the argument itself holds — `customer` is
        # both the raw id an arg puts there and the key `customer.status`
        # expects to dig into. If `args` merged last, the raw id (a
        # String) would win and `.status` on a String is where a fuzzer
        # found this — TypeError, not a refusal. Command-level
        # dereferencing is the one thing that is SUPPOSED to override
        # its own source argument for exactly this reason; args still
        # wins over stored OWNER state (unchanged from before this fix).
        # `parent:` is an entity command's OWN parent aggregate record
        # (EntityInterpreter's `ctx.instance` — "the PARENT aggregate
        # record", its own doc comment) — the entity's containment, not a
        # declared reference attribute, so it doesn't come from
        # `dereference`'s attribute scan the way `owner`'s do. Hydrated
        # the same shape regardless: the parent's own state, plus ITS OWN
        # references dereferenced one level in, so `parent.customer.status`
        # (a parent aggregate reaching ITS OWN customer) resolves the same
        # way `account.customer.status` does for a command-level reference.
        # nil for an aggregate command — CommandInterpreter never passes it.
        def enforce_givens(subject, command, args, domain:, parent: nil)
          state = GuardState.new(subject)
          owner = subject.aggregate if subject.respond_to?(:aggregate)
          attrs = dereference(domain, owner, subject).merge(args).merge(dereference(domain, command, args))
          attrs = attrs.merge(parent: dereference(domain, parent.aggregate, parent.state).merge(parent.state)) if parent
          command.givens.each do |given|
            next if Bluebook::Expression::Evaluator.call(given.canonical, state, attrs)

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
        def enforce_ensures(subject, command, args, old:, domain:, parent: nil)
          state = GuardState.new(subject)
          owner = subject.aggregate if subject.respond_to?(:aggregate)
          # Same merge-order reasoning as enforce_givens above: an
          # aliased command-level reference must override its own raw
          # id argument, not the other way round. `old` still wins over
          # everything, unchanged.
          attrs = dereference(domain, owner, subject).merge(args).merge(dereference(domain, command, args))
          attrs = attrs.merge(parent: dereference(domain, parent.aggregate, parent.state).merge(parent.state)) if parent
          attrs = attrs.merge(old: old)
          command.ensures.each do |rule|
            next if Bluebook::Expression::Evaluator.call(rule.canonical, state, attrs)

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
