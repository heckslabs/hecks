require_relative "interpreting"
require_relative "../naming"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "instance"
require_relative "value"
require_relative "refusal_wording"

module Hecksagain
  module Runtime
    class EntityInterpreter
      include Interpreting

      attr_reader :registry

      # THE DECLARED ORDER, HAND-TYPED — mirrors Vocabulary::EntityDispatchOrder
      # (language/bluebook/vocabulary.bluebook:217-232), held equal to it by
      # spec/vocabulary_conformance_spec.rb the same way CommandInterpreter's
      # own DISPATCH_ORDER is; see that constant's doc comment for why this is
      # hand-typed rather than read live off the meta-domain at every dispatch.
      # Shorter than the aggregate order for the same reasons the declaration
      # itself gives : no refuse_unknown_arguments/refuse_absent_arguments (an
      # entity inherits its aggregate's own gate) and no
      # assign_creation_attributes (an entity is never created through this
      # path).
      DISPATCH_ORDER = Hecksagain::Vocabulary.symbols("EntityDispatchOrder")

      # `instance` is the PARENT aggregate record (what gets saved and
      # returned) ; `element`/`view` are the entity piece itself — `view`
      # wraps `element` as it stood at `locate_element`, pre-mutation, and
      # `enforce_ensures` builds its own settled wrapper off `element` as it
      # stands after, the same split the original sequential code made.
      Context = Struct.new(:domain, :aggregate, :entity, :entity_name, :command, :command_name,
                            :args, :repository, :instance, :element, :view, :transition, :old_element, :result)

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, dotted, args)
        entity_name, command_name = Naming.split_dotted(dotted)
        entity  = aggregate.entities.find { |piece| piece.hecks_name == entity_name } ||
                  raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_unknown",
                                                            aggregate: aggregate.hecks_name, entity: entity_name.inspect))
        command = entity.command(command_name) ||
                  raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_no_command",
                                                            entity: entity_name, command: command_name.inspect))

        ctx = Context.new(domain, aggregate, entity, entity_name, command, command_name, args)
        run_dispatch_order(DISPATCH_ORDER, ctx)
        [ctx.instance, ctx.result]
      end

      private

      def step_normalize_args(ctx)
        ctx.args = step(:normalize_args) { normalize_args(ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_refuse_role_mismatch(ctx)
        step(:refuse_role_mismatch) { @rules.refuse_role_mismatch(ctx.command, ctx.domain) }
      end

      def step_resolve_references(ctx)
        step(:resolve_references) { @rules.resolve_references(ctx.domain, ctx.command, ctx.args) }
      end

      def step_hydrate_parent(ctx)
        ctx.repository = @registry.repository(ctx.domain, ctx.aggregate)
        ctx.instance = step(:hydrate_parent) { parent(ctx.repository, ctx.aggregate, ctx.entity_name, ctx.command_name, ctx.args) }
      end

      def step_locate_element(ctx)
        ctx.element = step(:locate_element) { element_of(ctx.aggregate, ctx.entity, ctx.entity_name, ctx.command_name, ctx.instance, ctx.args) }
        # `view` was hydrated ONCE, here, into its OWN state hash
        # (Value.hydrate builds a fresh Hash — never aliased with `element`)
        # — exactly right for enforce_givens, which must read pre-mutation.
        ctx.view = Instance.new(aggregate: ctx.entity, id: element_identity(ctx.entity, ctx.element).to_s, state: ctx.element)
      end

      def step_enforce_givens(ctx)
        step(:enforce_givens) { @rules.enforce_givens(ctx.view, ctx.command, ctx.args, domain: ctx.domain, declaring: ctx.entity, parent: ctx.instance) }
      end

      def step_admissible_transition(ctx)
        ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.entity, ctx.command, ctx.view) }
      end

      def step_apply_mutations(ctx)
        ctx.old_element = ctx.element.dup unless ctx.command.ensures.empty?
        step(:apply_mutations) { ctx.command.mutations.each { |mutation| apply_to_element(ctx.aggregate, ctx.entity, ctx.element, mutation, ctx.args) } }
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.element[ctx.entity.lifecycle.field] = ctx.transition.target }
      end

      # An ensures reads the SETTLED record, so it needs a view hydrated from
      # `element` as it stands now, mutations included — unlike `view` above,
      # built once and read pre-mutation by enforce_givens.
      def step_enforce_ensures(ctx)
        step(:enforce_ensures) do
          settled = Instance.new(aggregate: ctx.entity, id: ctx.view.id, state: ctx.element)
          @rules.enforce_ensures(settled, ctx.command, ctx.args, old: ctx.old_element, domain: ctx.domain, parent: ctx.instance)
        end
      end

      # THE PARENT AGGREGATE's own invariants — `ctx.instance` is the
      # parent record an entity mutation writes into (this file's own
      # `Context` comment), the SAME boundary an aggregate-level
      # invariant guards regardless of which interpreter changed it. No
      # separate "entity invariant" exists (S10, ADR 0025 scopes
      # `invariant` to the aggregate only) — see `Admissibility#
      # enforce_invariants`'s own comment.
      def step_enforce_invariants(ctx)
        step(:enforce_invariants) { @rules.enforce_invariants(ctx.instance, ctx.aggregate, domain: ctx.domain) }
      end

      def step_save(ctx)
        step(:save) { ctx.repository.save(ctx.instance) }
      end

      def step_emit(ctx)
        ctx.result = step(:emit) { @rules.emit(ctx.command, ctx.domain, ctx.aggregate, ctx.instance, ctx.args, ctx.repository) }
      end

      # THE PARENT AGGREGATE, addressed exactly as `CommandInterpreter#hydrate`
      # addresses one acting on itself — derive from the declared identity first
      # (`Identity.of`), and let a bare `id:` name an already-derived record when
      # the identity itself is not what the caller is holding.
      def parent(repository, aggregate, entity_name, command_name, args)
        parent_id = Identity.of(aggregate, args) ||
                    Identity.from(aggregate, args, :id) ||
                    raise(NotFound, RefusalWording.render("NotFound", "entity_parent_no_identity",
                                                           command: command_name, aggregate: aggregate.hecks_name,
                                                           entity: entity_name, identity: Identity.reading(aggregate)))
        found = repository.find(parent_id) ||
                raise(NotFound, RefusalWording.render("NotFound", "record_missing",
                                                       aggregate: aggregate.hecks_name,
                                                       identity: Identity.reading(aggregate),
                                                       offered: Rendering.describe(parent_id)))
        found.dup
      end

      # ONE ELEMENT, MATCHED ON EVERY PART OF ITS IDENTITY — not just the first.
      # A piece's identity may be several paths, the same shape a head's can be,
      # so a dispatch that names the element has to supply every part and every
      # part has to agree with the stored one.
      def element_of(aggregate, entity, entity_name, command_name, instance, args)
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_holds_no_list",
                                                              aggregate: aggregate.hecks_name, entity: entity_name))

        wants = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          raw  = args[head] ||
                 raise(NotFound, RefusalWording.render("NotFound", "entity_element_no_identity",
                                                        command: command_name, entity: entity_name,
                                                        identity: Identity.reading(entity)))

          [head, path, Value.for_attribute(aggregate, entity.attribute(head), raw)]
        end

        original = Array(instance[list_attr.name])
        position = original.find_index { |el| wants.all? { |head, _path, want| el[head] == want } }
        unless position
          raise NotFound, RefusalWording.render(
            "NotFound", "entity_element_missing",
            entity: entity_name, identity: Identity.reading(entity),
            wants: wants.map { |_h, path, want| Identity.scalar(path, want) }.join(", "),
            aggregate: aggregate.hecks_name, parent_id: instance.id.inspect
          )
        end

        # ONE LEVEL DEEPER THAN Instance#dup, for the same reason: a list
        # attribute holds Hashes, and `apply_to_element` mutates the found
        # one IN PLACE — the update mechanism for an entity, not a bug. But
        # in place means aliased with the adapter's own record until this
        # copies the array and the target element before handing either
        # back, and writes the fresh array into `instance` so the copy is
        # what persists on success and NOTHING aliased survives a refusal.
        copied  = original.dup
        element = copied[position].dup
        copied[position] = element
        instance[list_attr.name] = copied
        element
      end

      # THE ELEMENT'S OWN IDENTITY, joined from its parts — the entity-level
      # twin of `Identity.of`, reading off the STORED ELEMENT (a Hash) rather
      # than a dispatch payload. An id is a SCALAR, and the PATH is how it is
      # reached — never by opening a value object and taking whatever single
      # field is inside. That unwrapping is gone from the language : a piece
      # that does not name its fields is refused when the bluebook loads ("an
      # entity says what it is known by", "an identity part names something"),
      # so by the time a dispatch arrives here there is always a path to dig.
      def element_identity(entity, element)
        parts = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          Identity.scalar(path, element[head])
        end

        Naming.identity(parts)
      end

      # S17, ADR 0026 — `:append`/`:remove`/`:multiply`/`:clamp`, an
      # entity-scoped mirror of `CommandInterpreter::MutationApplier
      # #apply`'s own four (that module's own header names each one's
      # origin). Missing until now — an entity-owned command declaring
      # `sets :some_list, append: {...}` matched no `when` here and
      # silently no-opped, the one place this language otherwise
      # refuses what it cannot check applying nothing instead. `Member`/
      # `Dispatch` (S17) are the first real callers: both need to
      # append a value-object-typed element (`Pair`/`Binding`) onto a
      # list attribute THEY OWN, once they become entities of
      # `ValueObject`/`ProcessManager` rather than separate aggregates.
      #
      # `:increment`/`:decrement`/`:multiply` ALSO fixed here, found
      # while proving this method against a real fixture: they wrapped
      # `amount` unconditionally whenever `attribute` existed, the same
      # asymmetric-wrapping shape `MutationApplier#rewrap_arithmetic_
      # result`'s own comment documents fixing at the aggregate level
      # (migration plan task 9) — a phantom-created VO-typed field's
      # `current` reads back a raw, unwrapped default, `amount` was
      # wrapped anyway, and the two sides of one arithmetic call
      # disagreed on Value-ness. Confirmed live, not theoretical: this
      # method's own fixture (TaggedList.Bump, a VO-typed `count` with
      # `default: 0`) raised exactly this TypeMismatch on its first
      # real run.
      def apply_to_element(aggregate, entity, element, mutation, args)
        case mutation.op
        when :set
          value = @rules.resolve_source(mutation.source, args)
          attribute = entity.attribute(mutation.target)
          element[mutation.target] = attribute ? Value.for_attribute(aggregate, attribute, value) : value
        when :append
          element[mutation.target] = appended_to_element(aggregate, entity, element, mutation, args)
        when :remove
          element[mutation.target] = removed_from_element(aggregate, entity, element, mutation, args)
        when :increment, :decrement
          attribute = entity.attribute(mutation.target)
          amount    = @rules.resolve_source(mutation.source, args)
          current   = element[mutation.target]
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = @rules.arithmetic(current, amount, mutation.target, @rules.sign_of(mutation.op))
          element[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        when :multiply
          attribute = entity.attribute(mutation.target)
          amount    = @rules.resolve_source(mutation.source, args)
          current   = element[mutation.target]
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = @rules.multiply(current, amount, mutation.target)
          element[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        when :clamp
          element[mutation.target] = @rules.clamp(element[mutation.target], mutation.source, mutation.target)
        else
          # The aggregate-level twin's own backstop
          # (MutationApplier#apply), for the same reason: applying
          # nothing and refusing nothing would be the one silent
          # no-op in a language that otherwise refuses what it cannot
          # check.
          raise WiringError, "no entity mutation applier handles :#{mutation.op} — add one before declaring it"
        end
      end

      # `MutationApplier#rewrap_arithmetic_result`'s own entity-scoped
      # twin, byte-for-byte the same fix — see that method's own
      # comment for the full "phantom-field asymmetric wrapping" story.
      # A no-op whenever `current` was already a Value (the arithmetic
      # call already returned one) or the mutation targets no declared
      # attribute at all.
      def rewrap_arithmetic_result(aggregate, attribute, current, result)
        return result if current.is_a?(Value) || attribute.nil? || result.is_a?(Value)

        Value.for_attribute(aggregate, attribute, result)
      end

      # `MutationApplier#resolve_append_source`'s own entity-scoped
      # twin — a caller-supplied ARG first, falling back to the
      # ELEMENT's own current field (never the parent instance's) when
      # it isn't one.
      def resolve_element_append_source(source, element, args)
        return source unless source.is_a?(Symbol)
        return args[source] if args.key?(source)

        element[source]
      end

      # `MutationApplier#appended`'s own entity-scoped twin. VALUE-
      # OBJECT elements only — an entity's own list, appended to by an
      # entity-owned command, holds a value object (`Member.pairs`'
      # own `Pair`, `Dispatch.with_spec`'s own `Binding`) the same way
      # every real corpus append does; entity-in-entity nesting (a
      # list of ANOTHER entity, owned by this one) is out of scope —
      # `MutationApplier#entity_element`'s own fallback is deliberately
      # not mirrored here, since nothing in this language's own
      # `EntityBuilder` can declare a nested entity to need it (see
      # S17's own scoping note on why Dispatch flattens under
      # ProcessManager instead of nesting under Handler).
      def appended_to_element(aggregate, entity, element, mutation, args)
        fields       = mutation.source.transform_values { |source| resolve_element_append_source(source, element, args) }
        element_type = entity.attribute(mutation.target)&.type
        value_object = aggregate.value_object(element_type)
        if value_object
          value_object.attributes.each do |attribute|
            fields[attribute.name] = Value.scalar(fields[attribute.name]) if fields[attribute.name].is_a?(Value)
          end
        end
        appended = value_object ? Value.build(value_object, fields) : fields
        Freezer.deep(Array(element[mutation.target]) + [appended])
      end

      # `MutationApplier#removed`'s own entity-scoped twin — matches by
      # VALUE EQUALITY, element-wise, the same "so a concurrent Add can
      # never be lost" reasoning that method's own comment gives.
      def removed_from_element(aggregate, entity, element, mutation, args)
        value     = @rules.resolve_source(mutation.source, args)
        attribute = entity.attribute(mutation.target)
        value     = Value.for_attribute(aggregate, attribute, value) if attribute
        Array(element[mutation.target]).reject { |candidate| candidate == value }
      end
    end
  end
end
