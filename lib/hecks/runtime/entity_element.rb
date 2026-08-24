require_relative "../naming"
require_relative "../freezer"
require_relative "value"
require_relative "refusal_wording"
require_relative "errors"
require_relative "identity"

module Hecks
  module Runtime
    # ONE ENTITY ELEMENT, LOCATED AND MUTATED — the walk-and-write half of
    # dispatching into a piece an aggregate holds, factored out of
    # `EntityInterpreter` so a SECOND caller (`CommandInterpreter`'s own
    # `delegate_to_entity` step) can locate and mutate the SAME element the
    # same way, against an aggregate record it already holds in memory
    # rather than one freshly loaded from a repository. `EntityInterpreter`
    # keeps its own dispatch order and Context; this is the part underneath
    # that both now share, so it exists in exactly one place rather than two
    # that could only ever drift (the same reasoning `Runtime::Identity`'s
    # own header gives for the join/dig/reading trio it centralizes).
    #
    # `rules` (a `CommandRules` instance) is passed explicitly throughout
    # rather than closed over, since this module has no instance of its own
    # to hold one.
    module EntityElement
      module_function

      # ONE HOP PER CHAIN ENTRY. `container` starts as `instance` (the root
      # aggregate record) and becomes each just-located element in turn —
      # Dispatch's own element is found INSIDE the Handler element
      # `locate_chain` located the step before, never inside `instance`
      # directly. `owner` is whichever construct's OWN attribute declares
      # the list being searched (Handler declares `dispatches` ; the root
      # aggregate declares `handlers`) — `root_aggregate` stays the ROOT
      # the whole way through instead, passed to `element_of` separately,
      # because coercion (`Value.for_attribute`) resolves value objects
      # against the root's own namespace only ; an entity must never
      # answer `.value_object` (Entity's own header comment) so handing
      # it an intermediate owner instead would break every VO-typed
      # identity field a nested entity declares.
      #
      # `route`, if given, is the routing envelope's own entity chain
      # (`ctx.route.entities`, one entry per hop) — the routing/payload
      # split's own consequence: an entity's own identity may arrive via
      # `to:` rather than duplicated into `args`, so each hop is offered
      # its routed identity ahead of falling back to `args`.
      def locate_chain(root_aggregate, chain, instance, args, command_name, route = nil)
        container = instance
        owner     = root_aggregate
        chain.each_with_index do |entity, index|
          container = element_of(root_aggregate, owner, entity, command_name, container, args,
                                 route&.entities&.fetch(index))
          owner = entity
        end
        container
      end

      # ONE ELEMENT, MATCHED ON EVERY PART OF ITS IDENTITY — not just the first.
      # A piece's identity may be several paths, the same shape a head's can be,
      # so a dispatch that names the element has to supply every part and every
      # part has to agree with the stored one. `routed_identity`, when given,
      # matches by the element's own minted identity string directly instead
      # (`element_identity`, below) — the routing envelope already resolved
      # which element it means, so re-deriving `wants` from `args` would be
      # redundant at best and wrong if `args` no longer carries that identity
      # at all.
      def element_of(root_aggregate, owner, entity, command_name, container, args, routed_identity = nil)
        entity_name = entity.hecks_name
        list_attr = owner.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_holds_no_list",
                                                             aggregate: owner.hecks_name, entity: entity_name))

        wants = unless routed_identity
                  entity.identity_paths.map do |path|
                    head = path.to_s.split(".").first.to_sym
                    raw  = args[head] ||
                           raise(NotFound, RefusalWording.render("NotFound", "entity_element_no_identity",
                                                                 command: command_name, entity: entity_name,
                                                                 identity: Identity.reading(entity)))

                    [head, path, Value.for_attribute(root_aggregate, entity.attribute(head), raw)]
                  end
                end

        original = Array(container[list_attr.name])
        position = if routed_identity
                     original.find_index { |element| element_identity(entity, element).to_s == routed_identity.to_s }
                   else
                     original.find_index { |el| wants.all? { |head, _path, want| el[head] == want } }
                   end
        unless position
          raise NotFound, RefusalWording.render(
            "NotFound", "entity_element_missing",
            entity: entity_name, identity: Identity.reading(entity),
            wants: wants&.map { |_h, path, want| Identity.scalar(path, want) }&.join(", "),
            aggregate: owner.hecks_name,
            parent_id: container.respond_to?(:id) ? container.id.inspect : Rendering.describe(container)
          )
        end

        # ONE LEVEL DEEPER THAN Instance#dup, for the same reason: a list
        # attribute holds Hashes, and `apply_to_element` mutates the found
        # one IN PLACE — the update mechanism for an entity, not a bug. But
        # in place means aliased with the adapter's own record until this
        # copies the array and the target element before handing either
        # back, and writes the fresh array into `container` so the copy is
        # what persists on success and NOTHING aliased survives a refusal.
        # `container[list_attr.name] = copied` reaches `instance` itself
        # when this is the FIRST hop, and reaches the (already copied)
        # PARENT element when it is a later one — either way it is the
        # SAME already-fresh object `locate_chain` is about to hand back
        # as `container` for the next hop, so nothing further has to
        # propagate a write back up the chain by hand.
        copied  = original.dup
        element = copied[position].dup
        copied[position] = element
        container[list_attr.name] = copied
        element
      end

      # THE ELEMENT'S OWN IDENTITY, joined from its parts — the entity-level
      # twin of `Identity.of`, reading off the STORED ELEMENT (a Hash) rather
      # than a dispatch payload. An id is a SCALAR, and the PATH is how it is
      # reached — never by opening a value object and taking whatever single
      # field is inside. That unwrapping is gone from the language: a piece
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
      def apply_to_element(rules, aggregate, entity, element, mutation, args)
        case mutation.op
        when :set
          value = rules.resolve_source(mutation.source, args)
          attribute = entity.attribute(mutation.target)
          element[mutation.target] = attribute ? Value.for_attribute(aggregate, attribute, value) : value
        when :append
          element[mutation.target] = appended_to_element(aggregate, entity, element, mutation, args)
        when :remove
          element[mutation.target] = removed_from_element(rules, aggregate, entity, element, mutation, args)
        when :increment, :decrement
          attribute = entity.attribute(mutation.target)
          amount    = rules.resolve_source(mutation.source, args)
          current   = element[mutation.target]
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = rules.arithmetic(current, amount, mutation.target, rules.sign_of(mutation.op))
          element[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        when :multiply
          attribute = entity.attribute(mutation.target)
          amount    = rules.resolve_source(mutation.source, args)
          current   = element[mutation.target]
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = rules.multiply(current, amount, mutation.target)
          element[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        when :clamp
          element[mutation.target] = rules.clamp(element[mutation.target], mutation.source, mutation.target)
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
        value_object&.attributes&.each do |attribute|
          fields[attribute.name] = Value.scalar(fields[attribute.name]) if fields[attribute.name].is_a?(Value)
        end
        appended = value_object ? Value.build(value_object, fields, aggregate) : fields
        Freezer.deep(Array(element[mutation.target]) + [appended])
      end

      # `MutationApplier#removed`'s own entity-scoped twin — matches by
      # VALUE EQUALITY, element-wise, the same "so a concurrent Add can
      # never be lost" reasoning that method's own comment gives.
      def removed_from_element(rules, aggregate, entity, element, mutation, args)
        value     = rules.resolve_source(mutation.source, args)
        attribute = entity.attribute(mutation.target)
        value     = Value.for_attribute(aggregate, attribute, value) if attribute
        Array(element[mutation.target]).reject { |candidate| candidate == value }
      end
    end
  end
end
