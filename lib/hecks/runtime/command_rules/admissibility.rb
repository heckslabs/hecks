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
            # S12, ADR 0025 — a SEPARATE index, the same reason
            # `Aggregate#projected_fields` is a separate IR collection
            # rather than folded into `attributes` (see that field's
            # own comment): a projected field's absence means
            # something different from an ordinary attribute's, so it
            # needs its own refusal below, not `AttributeAbsent`'s.
            # `projects` is AGGREGATE-scoped only — an entity's own
            # `instance.aggregate` answers the ENTITY construct here
            # (EntityInterpreter's own subject), which declares no
            # `projected_fields` of its own, hence the extra guard
            # `@declared` above does not need.
            owner = instance.aggregate if instance.respond_to?(:aggregate)
            @projected = owner.respond_to?(:projected_fields) ? owner.projected_fields.to_h { |f| [f.name, f] } : {}
          end

          def key?(name) = @declared.key?(name.to_sym) || @projected.key?(name.to_sym) || @instance.key?(name)

          def [](name)
            return @instance[name] if @instance.key?(name)

            projected = @projected[name.to_sym]
            return raise_projection_absent(projected) if projected

            attribute = @declared[name.to_sym]
            return nil if attribute.nil? || attribute.optional?

            raise AttributeAbsent,
                  RefusalWording.render("AttributeAbsent", "absent_read",
                                        aggregate: @instance.aggregate.hecks_name, field: name)
          end

          private

          def raise_projection_absent(projected)
            raise ProjectionAbsent,
                  RefusalWording.render("ProjectionAbsent", "absent_read",
                                        aggregate: @instance.aggregate.hecks_name, field: projected.name,
                                        reference: projected.reference, remote_field: projected.remote_field)
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
        # the same shape regardless: the parent's own state, MERGED so
        # the dereferenced hash wins over the raw reference it replaces
        # (ADR 0025 dropped the `_id` suffix that used to keep the two
        # apart by name, so `parent.state.merge(dereference(...))` is
        # now load-bearing, not redundant) — plus ITS OWN references
        # dereferenced one level in, so `parent.customer.status` (a
        # parent aggregate reaching ITS OWN customer) resolves the same
        # way `account.customer.status` does for a command-level reference.
        # nil for an aggregate command — CommandInterpreter never passes it.
        def enforce_givens(subject, command, args, domain:, declaring: nil, parent: nil)
          state = GuardState.new(subject)
          # A RULE MAY ONLY READ WITHIN ITS OWN AGGREGATE BOUNDARY (S12,
          # ADR 0025) — `subject`'s own STORED references are no longer
          # dereferenced here at all. What used to be a live query against
          # another aggregate's own repository is now just `subject`'s own
          # state: a `projects :customer_status, from: :"customer.status"`
          # field is a REGULAR stored attribute, already present in
          # `subject`/`state` with no hydration step needed. `dereference`
          # is still called on `command`/`args`, below — that is a
          # DIFFERENT case the ADR explicitly keeps in bounds ("its command
          # arguments"): a reference-typed ARGUMENT this dispatch was just
          # handed (`Dispute`'s own `disputed_by`, say) has nothing stored
          # to project yet, so resolving it here, once, synchronously with
          # THIS command's own admission, is not the live-query-against-
          # another-aggregate's-stored-state pattern the boundary rule
          # forbids.
          attrs = args.merge(dereference(domain, command, args))
          attrs = attrs.merge(parent: parent.state) if parent
          command.givens.each do |given|
            next if Bluebook::Expression::Evaluator.call(given.canonical, state, attrs)

            raise GivenNotMet, "#{command.hecks_name} refused — #{given.description}"
          end

          enforce_lifecycle_guard(declaring, command, subject) if declaring
        end

        # `corrects` — CommandBuilder#corrects_impl's own comment. NOT
        # expressible as an ordinary `given`: "has this exact record
        # already emitted this exact event" is not a predicate over the
        # record's OWN fields, it is a fact about the event log, so it is
        # raised structurally here, the same way NotFound/AlreadyExists
        # are, rather than through the expression evaluator. The build-
        # time half — does ANYTHING in this aggregate ever emit the named
        # event at all — is `AggregateBuilder#seal_correction_targets`;
        # this is the dispatch-time half — has THIS record actually done
        # so yet.
        def enforce_correction_target(instance, aggregate, command, domain:)
          command.mutations.each do |mutation|
            next unless mutation.op == :corrects

            event_key  = "#{domain}::#{aggregate.hecks_name}"
            event_name = mutation.target.to_s
            next if @registry.event_log.any? do |event|
              event.name == event_name && event.aggregate == event_key && event.id == instance.id
            end

            raise NothingToCorrect,
                  "#{command.hecks_name} refused — corrects #{event_name}, but " \
                  "#{event_key} ##{instance.id} has never emitted it"
          end
        end

        # LIFECYCLE STATE AS A COMMAND GUARD (S10, ADR 0025) — `command
        # "Debit", from: "open"` checked here, folded into the SAME
        # dispatch step `given` already runs at (both are preconditions,
        # evaluated before any mutation) rather than earning its own
        # DISPATCH_ORDER entry. A GUARD, never a transition: it names no
        # target state and `step_advance_lifecycle` never sees it — see
        # `admissible_transition`, right below, for the transition this
        # is deliberately NOT reusing (its own `StateTransition#target`
        # is required, and a guard-only command has none to give it).
        def enforce_lifecycle_guard(declaring, command, subject)
          return unless command.from

          lifecycle = declaring.lifecycle
          current   = Value.scalar(subject[lifecycle.field]).to_s
          return if Array(command.from).include?(current)

          # ROUTED THROUGH RefusalWording's OWN "transition_blocked"
          # TEMPLATE — the same one #admissible_transition, right below,
          # already raises LifecycleRefused through for the same
          # refusal class. This used to hand-roll its own wording
          # inline ("...only runs from..." vs. the template's "...moves
          # it only from...") — two shapes for one refusal kind, so
          # anything string-matching a LifecycleRefused message (a
          # property, a spec, a caller) had to know both existed rather
          # than one.
          raise LifecycleRefused,
                RefusalWording.render("LifecycleRefused", "transition_blocked",
                                      command: command.hecks_name, field: lifecycle.field,
                                      current: Rendering.describe(current),
                                      allowed: Array(command.from).map(&:inspect).join(" or "))
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
          # S12, ADR 0025 — same boundary reasoning as enforce_givens
          # above: `subject`'s own stored references are no longer
          # dereferenced here; a `projects`-maintained field is already
          # part of `state`. `command`/`args` still dereferences — a
          # fresh reference-typed ARGUMENT stays in bounds.
          # `old` still wins over everything, unchanged.
          attrs = args.merge(dereference(domain, command, args))
          attrs = attrs.merge(parent: parent.state) if parent
          attrs = attrs.merge(old: old)
          command.ensures.each do |rule|
            next if Bluebook::Expression::Evaluator.call(rule.canonical, state, attrs)

            raise EnsuresNotMet, "#{command.hecks_name} refused — #{rule.description}"
          end
        end

        # THE AGGREGATE BOUNDARY, checked after every command, before
        # save (S10, ADR 0025 — "Rules") — the same point `enforce_
        # ensures` already checks at, and for the same reason: an
        # invariant is a claim about the SETTLED record, not the
        # command that produced it, so it reads no `args`/`old` at all,
        # only the record's own state. `subject` here is
        # always the AGGREGATE's own instance — `CommandInterpreter`
        # passes its own `ctx.instance`, and `EntityInterpreter` passes
        # the PARENT record (`ctx.instance`, not the element), since an
        # entity mutation changes data inside the SAME aggregate
        # boundary the invariant guards; there is no separate "entity
        # invariant" to check the piece's own view against.
        #
        # NO `dereference` (S12, ADR 0025) — an invariant may only read
        # `subject`'s own boundary, same rule `enforce_givens`/
        # `enforce_ensures` now hold to. No invariant in the corpus has
        # ever read across a `reference_to` (verified before this
        # change), so this is not a migration, just closing the same
        # capability off here that was already unused.
        def enforce_invariants(subject, aggregate, domain:)
          state = GuardState.new(subject)
          attrs = {}
          aggregate.invariants.each do |invariant|
            next if Bluebook::Expression::Evaluator.call(invariant.canonical, state, attrs)

            raise InvariantViolation, "#{aggregate.hecks_name} refused — #{invariant.description}"
          end

          check_entity_invariants(aggregate, subject, domain: domain)
        end

        # A PIECE'S OWN SHAPE RULE, checked against EVERY INSTANCE the
        # aggregate holds — not a separate boundary from the aggregate's
        # own invariants just above (same two checkpoints: after every
        # mutation, before save), just a WIDER one: the aggregate's own
        # consistency includes each of its pieces individually looking
        # right, the same way `ValueObject#invariants` already checks
        # each of ITS OWN instances one construct up. RECURSES into
        # nested pieces (S17, ADR 0026 — Dispatch inside Handler) the
        # same way `check_entity_invariants`'s own caller recurses
        # nowhere else needs to, since a piece's `entities` are already
        # exactly as reachable as an aggregate's.
        #
        # `list_attr` reuses the EXACT lookup `EntityInterpreter#
        # element_of` already makes to locate a SINGLE addressed
        # element by identity — this reads every element instead, but
        # the "which field on the owner holds this piece's own
        # instances" question is the identical one. A piece declaring
        # invariants that nothing on its owner actually holds (no
        # matching list attribute) is a static-analysis gap for a
        # future gate, not a runtime concern here — `next` past it
        # rather than raising mid-enforcement for an unrelated command.
        def check_entity_invariants(owner_construct, owner_instance, domain:)
          owner_construct.entities.each do |entity|
            next if entity.invariants.empty?

            list_attr = owner_construct.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name }
            next unless list_attr

            Array(owner_instance[list_attr.name]).each do |element|
              wrapped = Instance.new(aggregate: entity, id: nil, state: element)
              element_state = GuardState.new(wrapped)
              # NO `dereference` (S12, ADR 0025) — same boundary rule as
              # enforce_invariants above; `parent` (the owner's own
              # state, projected fields included) stays readable.
              attrs = { parent: owner_instance.state }

              entity.invariants.each do |invariant|
                next if Bluebook::Expression::Evaluator.call(invariant.canonical, element_state, attrs)

                raise InvariantViolation, "#{entity.hecks_name} refused — #{invariant.description}"
              end

              check_entity_invariants(entity, wrapped, domain: domain)
            end
          end
        end

        def admissible_transition(declaring, command, subject)
          lifecycle = declaring.lifecycle
          return nil unless lifecycle

          candidates = lifecycle.transitions_for(command.hecks_name)
          return nil if candidates.empty?

          # `Value.scalar` unwrap -- vendored addition, not (yet)
          # upstream hecks (migration plan task 9): a VO-typed
          # lifecycle field (the norm, not the exception, per this
          # corpus's own no-primitive-envy convention) holds a real
          # `Runtime::Value` here, and a bare `.to_s` on that hit Ruby's
          # default `Object#to_s` instead of unwrapping the inner
          # scalar first -- `current` came back as a raw object-pointer
          # string (`"#<Hecks::Runtime::Value:0x...>"`) that could
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
