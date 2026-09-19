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
        # Wraps `subject` so a guard can read a declared-but-storage-absent
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
        # NIL is not the only outcome, though. The Item.Promote fix above
        # covered an optional field — the honest case, where absence is
        # exactly what optional means. It also, as a side effect, let a
        # non-optional field predating a record read nil the same way,
        # which is the `ne:`/array-`in:` bug class applied to rule
        # evaluation: a predicate silently answers against a value nobody
        # ever wrote (ADR 0025, "Added attributes and absence"). `[]`
        # below narrows the nil-read back to what it was built for —
        # optional stays nil, non-optional raises a named refusal
        # identifying the field, so a rule that reads it fails loud
        # instead of quietly wrong.
        class GuardState
          # @param instance [Runtime::Instance, Object] the record a rule reads; anything that
          #   does not respond to `aggregate` (an entity's own pre-mutation view) degrades to
          #   reading only `instance`'s own keys, with no declared or projected fields known
          def initialize(instance)
            @instance = instance
            @declared = instance.respond_to?(:aggregate) ? instance.aggregate.attributes.to_h { |a| [a.name, a] } : {}
            # S12, ADR 0025 — a separate index, the same reason
            # `Aggregate#projected_fields` is a separate IR collection
            # rather than folded into `attributes` (see that field's
            # own comment): a projected field's absence means
            # something different from an ordinary attribute's, so it
            # needs its own refusal below, not `AttributeAbsent`'s.
            # `projects` is aggregate-scoped only — an entity's own
            # `instance.aggregate` answers the entity construct here
            # (EntityInterpreter's own subject), which declares no
            # `projected_fields` of its own, hence the extra guard
            # `@declared` above does not need.
            owner = instance.aggregate if instance.respond_to?(:aggregate)
            @projected = owner.respond_to?(:projected_fields) ? owner.projected_fields.to_h { |f| [f.name, f] } : {}
          end

          # Answers whether a rule may read this name at all: a declared attribute, a
          # `projects`-maintained field, or a key the wrapped instance already holds.
          #
          # @param name [String, Symbol] the field name a rule references
          # @return [Boolean] true when the field is declared, projected, or already present
          def key?(name) = @declared.key?(name.to_sym) || @projected.key?(name.to_sym) || @instance.key?(name)

          # Reads one field the way a `given`/`ensures`/`invariant` rule sees it.
          #
          # @param name [String, Symbol] the field name a rule references
          # @return [Object, nil] the instance's own value when the key is already present;
          #   nil for a declared-but-absent optional attribute or an undeclared name
          # @raise [Runtime::AttributeAbsent] if a non-optional declared attribute is absent
          #   from the instance (a record predating that attribute)
          # @raise [Runtime::ProjectionAbsent] if a `projects`-maintained field is absent
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

        # Refuses the command unless every declared `given` holds, then checks its lifecycle
        # guard.
        #
        # `domain:` is only needed to dereference a reference-typed field
        # (`customer.status`) — see References#dereference. `owner` is the
        # declaring aggregate/entity when `subject` carries one (an
        # entity's pre-mutation `view` does, same as an aggregate's
        # `Instance`); a `subject` with no `.aggregate` just hydrates
        # nothing from state, same as GuardState degrades above.
        #
        # Merge order matters, and it is not "args always win": an
        # unaliased command-level reference dereferences under a
        # different name than the argument holds (`account_id` the arg,
        # `account` the hydrated key — no collision, order is moot). An
        # aliased one (`reference_to Customer, as: :customer`) hydrates
        # under the same name the argument itself holds — `customer` is
        # both the raw id an arg puts there and the key `customer.status`
        # expects to dig into. If `args` merged last, the raw id (a
        # String) would win and `.status` on a String is where a fuzzer
        # found this — TypeError, not a refusal. Command-level
        # dereferencing is the one thing that is supposed to override
        # its own source argument for exactly this reason; args still
        # wins over stored owner state.
        # `parent:` is an entity command's own parent aggregate record
        # (EntityInterpreter's `ctx.instance` — "the parent aggregate
        # record", its own doc comment) — the entity's containment, not a
        # declared reference attribute, so it doesn't come from
        # `dereference`'s attribute scan the way `owner`'s do. Hydrated
        # the same shape regardless: the parent's own state, merged so
        # the dereferenced hash wins over the raw reference it replaces
        # (ADR 0025 dropped the `_id` suffix that once kept the two
        # apart by name, so `parent.state.merge(dereference(...))` is
        # load-bearing, not redundant) — plus its own references
        # dereferenced one level in, so `parent.customer.status` (a
        # parent aggregate reaching its own customer) resolves the same
        # way `account.customer.status` does for a command-level reference.
        # nil for an aggregate command — CommandInterpreter never passes it.
        # `correction:` — the `{as_name => payload}` bindings
        # `enforce_correction_target` (above) already located, merged in
        # last so an `as:` name wins the same way `old:` always wins in
        # `enforce_ensures`, below — it is a fresh local binding a
        # `corrects` command introduces, not a real argument/state field
        # a caller could collide with by accident.
        #
        # @param subject [Runtime::Instance, Object] the record a `given` reads: the aggregate
        #   instance for a command, an entity's pre-mutation view for an entity command
        # @param command [Bluebook::Command] the command being admitted; its `givens` are
        #   evaluated in order
        # @param args [Hash{Symbol => Object}] the command's normalized arguments
        # @param domain [String] name of `command`'s domain, for dereferencing a
        #   reference-typed argument
        # @param declaring [Bluebook::Aggregate, Bluebook::Entity, nil] the construct that
        #   declares `command`'s lifecycle guard, if any; nil skips the lifecycle check
        # @param parent [Runtime::Instance, nil] an entity command's own parent aggregate
        #   record; nil for an aggregate command
        # @param correction [Hash{Symbol => Object}] `{as_name => payload}` bindings a
        #   `corrects` mutation already located, merged in last
        # @return [void]
        # @raise [Runtime::GivenNotMet] if any declared `given` does not hold
        # @raise [Runtime::LifecycleRefused] if `declaring` is given and the command's `from`
        #   guard does not admit the subject's current lifecycle state
        # @raise [Runtime::AttributeAbsent] if a `given` reads a non-optional declared
        #   attribute absent from the subject (a record predating that attribute)
        # @raise [Runtime::ProjectionAbsent] if a `given` reads a `projects`-maintained field
        #   that is absent
        # @raise [Bluebook::Expression::EvaluationError] if evaluating a `given` hits a
        #   runtime type fault (not a domain refusal)
        def enforce_givens(subject, command, args, domain:, declaring: nil, parent: nil, correction: {})
          state = GuardState.new(subject)
          # A rule may only read within its own aggregate boundary (S12,
          # ADR 0025) — `subject`'s own stored references are never
          # dereferenced here. What a live query against another
          # aggregate's own repository would answer is already just
          # `subject`'s own state: a `projects :customer_status, from: :"customer.status"`
          # field is a regular stored attribute, already present in
          # `subject`/`state` with no hydration step needed. `dereference`
          # is still called on `command`/`args`, below — that is a
          # different case the ADR explicitly keeps in bounds ("its command
          # arguments"): a reference-typed argument this dispatch was just
          # handed (`Dispute`'s own `disputed_by`, say) has nothing stored
          # to project yet, so resolving it here, once, synchronously with
          # this command's own admission, is not the live-query-against-
          # another-aggregate's-stored-state pattern the boundary rule
          # forbids.
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

        # `corrects` — CommandBuilder#corrects_impl's own comment. Not
        # expressible as an ordinary `given`: "has this exact record
        # already emitted this exact event" is not a predicate over the
        # record's own fields, it is a fact about the event log, so it is
        # raised structurally here, the same way NotFound/AlreadyExists
        # are, rather than through the expression evaluator. The build-
        # time half — does anything in this aggregate ever emit the named
        # event at all — is `AggregateBuilder#seal_correction_targets`;
        # this is the dispatch-time half — has this record actually done
        # so yet.
        #
        # Also locates the matched event now, not just its existence, and
        # returns a `{as_name => payload}` bindings hash — one entry per
        # `:corrects` mutation that named an `as:` — so `given`/`ensures`
        # on a corrects-bearing command can reference the located old
        # event by that name, the same shape `enforce_ensures`'s own
        # `old:` binding already has (CommandBuilder#corrects_impl's own
        # comment: `as:` was stored, from the start, specifically to be
        # wired into the evaluator once a real runtime consumer existed —
        # this is that consumer). `.reverse.find` — the most recent
        # matching event, if this record has somehow emitted the same
        # correction target more than once; the prior existence-only
        # check never had to make this choice, so it's a genuinely new
        # one, made deliberately: `as:` reads as "the instance being
        # corrected," which is naturally the latest fact on record, not
        # an arbitrary one.
        # C9.2 (docs/semantics/bluebook-semantics.md) — a correction target
        # is judged against the record's durable history: the events the
        # aggregate's own store recorded (`AppendOnly#events`), which
        # survive a restart the way the Rust kernel's persisted
        # `emitted_<event>` flag does. The in-process log is the fallback
        # only for an adapter that records no readable history.
        #
        # @param domain [String] name of the aggregate's domain
        # @param aggregate [Bluebook::Aggregate] the aggregate whose history is judged
        # @return [Array<Runtime::Event>] the aggregate's durably recorded events when the
        #   adapter keeps one, otherwise the registry's in-process event log
        def correction_history(domain, aggregate)
          @registry.repository(domain, aggregate).events || @registry.event_log
        end

        # Locates the event each `corrects` mutation names, refusing if the record never
        # emitted it, and returns the `as:`-bound bindings for `given`/`ensures` to read.
        #
        # @param instance [Runtime::Instance] the record being corrected
        # @param aggregate [Bluebook::Aggregate] the aggregate `instance` belongs to
        # @param command [Bluebook::Command] the command being admitted; its `:corrects`
        #   mutations name the events to locate
        # @param domain [String] name of `aggregate`'s domain
        # @return [Hash{Symbol => Object}] `{as_name => payload}`, one entry per `:corrects`
        #   mutation that named an `as:`; `{}` when the command corrects nothing, or names
        #   nothing as
        # @raise [Runtime::NothingToCorrect] if the record has never emitted an event a
        #   `:corrects` mutation names
        def enforce_correction_target(instance, aggregate, command, domain:)
          bindings = {}
          command.mutations.each do |mutation|
            next unless mutation.op == :corrects

            event_key  = "#{domain}::#{aggregate.hecks_name}"
            event_name = mutation.target.to_s
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

        # Refuses the command unless its `from:` lifecycle guard admits the subject's current
        # state.
        #
        # Lifecycle state as a command guard (S10, ADR 0025) — `command
        # "Debit", from: "open"` checked here, folded into the same
        # dispatch step `given` already runs at (both are preconditions,
        # evaluated before any mutation) rather than earning its own
        # DISPATCH_ORDER entry. A guard, never a transition: it names no
        # target state and `step_advance_lifecycle` never sees it — see
        # `admissible_transition`, right below, for the transition this
        # is deliberately not reusing (its own `StateTransition#target`
        # is required, and a guard-only command has none to give it).
        #
        # @param declaring [Bluebook::Aggregate, Bluebook::Entity] the construct whose
        #   `lifecycle` names the field this guard reads
        # @param command [Bluebook::Command] the command being admitted; nothing is checked
        #   when it declares no `from:`
        # @param subject [Runtime::Instance, Object] the record whose lifecycle field is read
        # @return [void]
        # @raise [Runtime::LifecycleRefused] if the command declares `from:` and the
        #   subject's current lifecycle state is not among the allowed states
        def enforce_lifecycle_guard(declaring, command, subject)
          return unless command.from

          lifecycle = declaring.lifecycle
          current   = Value.scalar(subject[lifecycle.field]).to_s
          return if Array(command.from).include?(current)

          # Routed through RefusalWording's own "transition_blocked"
          # template — the same one #admissible_transition, right below,
          # already raises LifecycleRefused through for the same
          # refusal class, rather than hand-rolling its own wording
          # inline. One shape for one refusal kind, so anything
          # string-matching a LifecycleRefused message (a
          # property, a spec, a caller) only has to know one.
          raise LifecycleRefused,
                RefusalWording.render_site("LifecycleRefused", "transition_blocked",
                                           command: command.hecks_name, field: lifecycle.field,
                                           current: Rendering.describe(current),
                                           allowed: Array(command.from))
        end

        # Refuses the command unless every declared `ensures` holds against the settled record.
        #
        # The far side of the contract: evaluated against the settled record
        # — after mutations and the lifecycle move, before anything persists
        # — with `old` carrying the state as the givens saw it. Injected into
        # the attrs at evaluation time only; the payload gate never sees it.
        #
        # `old` — and every dispatch argument — wins over a same-named state
        # field in expression scope (Resolver#fetch checks attrs first). An
        # ensures naming a field the command also takes as an argument (or,
        # on an entity, a field that doubles as the addressing argument
        # element_of reads) will read the argument, not the settled value.
        # Not new to ensures — `given` lives under the same rule — but an
        # ensures is more likely to collide, since it typically re-reads a
        # field the command just took in to mutate it.
        #
        # @param subject [Runtime::Instance, Object] the settled record an `ensures` reads
        # @param command [Bluebook::Command] the command being admitted; its `ensures` are
        #   evaluated in order
        # @param args [Hash{Symbol => Object}] the command's normalized arguments
        # @param old [Hash, Object] the state as the givens saw it, before this command's own
        #   mutations; always wins over a same-named state field
        # @param domain [String] name of `command`'s domain, for dereferencing a
        #   reference-typed argument
        # @param parent [Runtime::Instance, nil] an entity command's own parent aggregate
        #   record; nil for an aggregate command
        # @param correction [Hash{Symbol => Object}] `{as_name => payload}` bindings a
        #   `corrects` mutation already located, merged in alongside `old`
        # @return [void]
        # @raise [Runtime::EnsuresNotMet] if any declared `ensures` does not hold
        # @raise [Runtime::AttributeAbsent] if an `ensures` reads a non-optional declared
        #   attribute absent from the subject
        # @raise [Runtime::ProjectionAbsent] if an `ensures` reads a `projects`-maintained
        #   field that is absent
        # @raise [Bluebook::Expression::EvaluationError] if evaluating an `ensures` hits a
        #   runtime type fault (not a domain refusal)
        def enforce_ensures(subject, command, args, old:, domain:, parent: nil, correction: {})
          state = GuardState.new(subject)
          # S12, ADR 0025 — same boundary reasoning as enforce_givens
          # above: `subject`'s own stored references are no longer
          # dereferenced here; a `projects`-maintained field is already
          # part of `state`. `command`/`args` still dereferences — a
          # fresh reference-typed argument stays in bounds.
          # `old` still wins over everything, unchanged. `correction`
          # (an `as:`-bound corrected event, if this command declares
          # one) wins right alongside it — a settled-record ensures can
          # reference the correction target exactly as freely as a
          # pre-mutation given already can.
          # C2.3 (docs/semantics/bluebook-semantics.md) — an ensures reads
          # the settled state first: an argument that shares a field's
          # name does not shadow the candidate here (it does in a given,
          # C2.2), so `sets :note` + `ensures { note == ... }` judges what
          # landed, and `old.<field>` remains the pre-state.
          attrs = args.reject { |name, _| subject.key?(name) }.merge(dereference(domain, command, args))
          attrs = attrs.merge(parent: parent.state) if parent
          attrs = attrs.merge(correction) unless correction.empty?
          attrs = attrs.merge(old: old)
          command.ensures.each do |rule|
            next if Bluebook::Expression::Evaluator.call_rule(rule, state, attrs)

            raise EnsuresNotMet, "#{command.hecks_name} refused — #{rule.description}"
          end
        end

        # Refuses the command unless every declared aggregate and entity invariant holds
        # against the settled record.
        #
        # The aggregate boundary, checked after every command, before
        # save (S10, ADR 0025 — "Rules") — the same point `enforce_
        # ensures` already checks at, and for the same reason: an
        # invariant is a claim about the settled record, not the
        # command that produced it, so it reads no `args`/`old` at all,
        # only the record's own state. `subject` here is
        # always the aggregate's own instance — `CommandInterpreter`
        # passes its own `ctx.instance`, and `EntityInterpreter` passes
        # the parent record (`ctx.instance`, not the element), since an
        # entity mutation changes data inside the same aggregate
        # boundary the invariant guards; there is no separate "entity
        # invariant" to check the piece's own view against.
        #
        # No `dereference` (S12, ADR 0025) — an invariant may only read
        # `subject`'s own boundary, the same rule `enforce_givens`/
        # `enforce_ensures` hold to. No invariant in the corpus reads
        # across a `reference_to` (confirmed by inspecting every one),
        # so this closes off a capability that was already unused, not
        # a migration.
        #
        # @param subject [Runtime::Instance] the settled aggregate record; an entity command
        #   passes its parent record, never the element
        # @param aggregate [Bluebook::Aggregate] the aggregate whose `invariants` are checked
        # @param domain [String] name of `aggregate`'s domain, threaded through to
        #   `check_entity_invariants`
        # @return [void]
        # @raise [Runtime::InvariantViolation] if an aggregate invariant, or a nested entity's
        #   own invariant, does not hold
        # @raise [Runtime::AttributeAbsent] if an invariant reads a non-optional declared
        #   attribute absent from the subject
        # @raise [Runtime::ProjectionAbsent] if an invariant reads a `projects`-maintained
        #   field that is absent
        # @raise [Bluebook::Expression::EvaluationError] if evaluating an invariant hits a
        #   runtime type fault (not a domain refusal)
        def enforce_invariants(subject, aggregate, domain:)
          state = GuardState.new(subject)
          attrs = {}
          aggregate.invariants.each do |invariant|
            next if Bluebook::Expression::Evaluator.call_rule(invariant, state, attrs)

            raise InvariantViolation, "#{aggregate.hecks_name} refused — #{invariant.description}"
          end

          check_entity_invariants(aggregate, subject, domain: domain)
        end

        # A piece's own shape rule, checked against every instance the
        # aggregate holds — not a separate boundary from the aggregate's
        # own invariants just above (same two checkpoints: after every
        # mutation, before save), just a wider one: the aggregate's own
        # consistency includes each of its pieces individually looking
        # right, the same way `ValueObject#invariants` already checks
        # each of its own instances one construct up. Recurses into
        # nested pieces (S17, ADR 0026 — Dispatch inside Handler) the
        # same way `check_entity_invariants`'s own caller recurses
        # nowhere else needs to, since a piece's `entities` are already
        # exactly as reachable as an aggregate's.
        #
        # `list_attr` reuses the exact lookup `EntityInterpreter#
        # element_of` already makes to locate a single addressed
        # element by identity — this reads every element instead, but
        # the "which field on the owner holds this piece's own
        # instances" question is the identical one. A piece declaring
        # invariants that nothing on its owner actually holds (no
        # matching list attribute) is a static-analysis gap for a
        # future gate, not a runtime concern here — `next` past it
        # rather than raising mid-enforcement for an unrelated command.
        #
        # @param owner_construct [Bluebook::Aggregate, Bluebook::Entity] the construct whose
        #   `entities` are checked
        # @param owner_instance [Runtime::Instance] the settled record holding each entity's
        #   own list attribute
        # @param domain [String] name of the owning aggregate's domain; read through to a
        #   deeper recursive call, though no invariant may itself dereference
        # @return [void]
        # @raise [Runtime::InvariantViolation] if any entity element, at any nesting depth,
        #   fails one of its own declared invariants
        def check_entity_invariants(owner_construct, owner_instance, domain:)
          owner_construct.entities.each do |entity|
            next if entity.invariants.empty?

            list_attr = owner_construct.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name }
            next unless list_attr

            Array(owner_instance[list_attr.name]).each do |element|
              wrapped = Instance.new(aggregate: entity, id: nil, state: element)
              element_state = GuardState.new(wrapped)
              # No `dereference` (S12, ADR 0025) — same boundary rule as
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

        # Finds the lifecycle transition this command moves the subject through, refusing when
        # none of the command's declared transitions admits its current state.
        #
        # @param declaring [Bluebook::Aggregate, Bluebook::Entity] the construct whose
        #   `lifecycle` declares the transition table
        # @param command [Bluebook::Command] the command being dispatched
        # @param subject [Runtime::Instance, Object] the pre-mutation record, read for its
        #   current lifecycle field value
        # @return [Bluebook::StateTransition, nil] nil when `declaring` has no lifecycle, or
        #   the command names none of its transitions; otherwise the one admitted transition
        #   (unconstrained, or whose `from:` includes the subject's current state)
        # @raise [Runtime::LifecycleRefused] if the command names transitions but none is
        #   admitted from the subject's current state
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
          # never match any declared `from` state, so every transition
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
                RefusalWording.render_site("LifecycleRefused", "transition_blocked",
                                           command: command.hecks_name, field: lifecycle.field,
                                           current: Rendering.describe(current),
                                           allowed: allowed)
        end
      end
    end
  end
end
