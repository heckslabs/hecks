require_relative "../naming"
require_relative "../freezer"
require_relative "value"
require_relative "refusal_wording"
require_relative "errors"
require_relative "identity"
require_relative "instance"

module Hecks
  module Runtime
    # Locates and mutates one entity element within an aggregate record — the shared
    # implementation behind EntityInterpreter and CommandInterpreter's own delegation.
    module EntityElement
      module_function

      # A sentinel that never equals a stored element field, since a real field can hold nil.
      UNMATCHABLE = Object.new.freeze
      private_constant :UNMATCHABLE

      # Walks `chain` one hop at a time and returns the located element (or `instance`
      # itself when `chain` is empty). `route`, when given, offers each hop's identity
      # before falling back to `args`.
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

      # Locates one element, matching every part of its declared identity, and copies
      # the owning list and the element before any write so nothing aliases the caller's
      # record. `routed_identity`, when given, matches directly by the element's own
      # identity string instead of re-deriving `wants` from `args`.
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/PerceivedComplexity
      # rubocop:disable-next Metrics/MethodLength
      def element_of(root_aggregate, owner, entity, command_name, container, args, routed_identity = nil)
        entity_name = entity.hecks_name
        list_attr = owner.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_holds_no_list",
                                                                  aggregate: owner.hecks_name, entity: entity_name))

        wants = unless routed_identity
                  entity.identity_paths.map do |path|
                    head = path.to_s.split(".").first.to_sym
                    raw  = args[head] ||
                           raise(NotFound, RefusalWording.render_site("NotFound", "entity_element_no_identity",
                                                                      command: command_name, entity: entity_name,
                                                                      identity: Identity.reading(entity)))

                    # A value that fails its own type's invariant can never match a stored
                    # element (every stored one already satisfies it) — degrade to
                    # `UNMATCHABLE` here rather than letting InvariantViolation propagate.
                    want = begin
                      Value.for_attribute(root_aggregate, entity.attribute(head), raw)
                    rescue InvariantViolation
                      UNMATCHABLE
                    end

                    [head, path, want, raw]
                  end
                end

        original = Array(container[list_attr.name])
        position = if routed_identity
                     original.find_index { |element| element_identity(entity, element).to_s == routed_identity.to_s }
                   else
                     original.find_index do |el|
                       wants.all? { |head, _path, want, _raw| want != UNMATCHABLE && el[head] == want }
                     end
                   end
        unless position
          raise NotFound, RefusalWording.render_site(
            "NotFound", "entity_element_missing",
            entity: entity_name, identity: Identity.reading(entity),
            wants: wants&.map { |_h, path, _want, raw| Identity.scalar(path, raw) }&.join(", "),
            aggregate: owner.hecks_name,
            parent_id: container.respond_to?(:id) ? container.id.inspect : Rendering.describe(container)
          )
        end

        # Copies the list and the found element before handing either back — the list
        # attribute holds Hashes, and the caller mutates the returned element in place,
        # so this keeps that mutation off the adapter's own record until it commits.
        copied  = original.dup
        element = copied[position].dup
        copied[position] = element
        container[list_attr.name] = copied
        element
      end

      # An element's identity, joined from its declared identity paths (read off the
      # stored Hash, not a dispatch payload).
      def element_identity(entity, element)
        parts = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          Identity.scalar(path, element[head])
        end

        Naming.identity(parts)
      end

      # Applies one declared mutation to an entity element, in place. `pre` is the
      # element as it stood before this command: every read goes through it, every
      # write lands on `element`.
      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity
      def apply_to_element(rules, aggregate, entity, element, mutation, args, pre = element)
        case mutation.op
        when :set
          value = rules.resolve_source(mutation.source, args)
          attribute = entity.attribute(mutation.target)
          element[mutation.target] = attribute ? Value.for_attribute(aggregate, attribute, value) : value
        when :append
          element[mutation.target] = appended_to_element(aggregate, entity, pre, mutation, args)
        when :remove
          element[mutation.target] = removed_from_element(rules, aggregate, entity, pre, mutation, args)
        when :increment, :decrement
          attribute = entity.attribute(mutation.target)
          amount    = rules.resolve_source(mutation.source, args)
          current   = pre[mutation.target]
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = rules.arithmetic(current, amount, mutation.target, rules.sign_of(mutation.op))
          element[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        when :multiply
          attribute = entity.attribute(mutation.target)
          amount    = rules.resolve_source(mutation.source, args)
          current   = pre[mutation.target]
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = rules.multiply(current, amount, mutation.target)
          element[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        when :clamp
          element[mutation.target] = rules.clamp(pre[mutation.target], mutation.source, mutation.target)
        # `corrects`: a no-op here; the target event was already checked by
        # EntityInterpreter#step_enforce_givens.
        when :corrects
          nil
        else
          # Backstop: an unhandled op must refuse, not silently apply nothing.
          raise WiringError, "no entity mutation applier handles :#{mutation.op} — add one before declaring it"
        end
      end

      # Rewraps a plain-Numeric arithmetic result into the attribute's own Value type.
      # A no-op when `current` was already a Value, or the mutation targets no attribute.
      def rewrap_arithmetic_result(aggregate, attribute, current, result)
        return result if current.is_a?(Value) || attribute.nil? || result.is_a?(Value)

        Value.for_attribute(aggregate, attribute, result)
      end

      # A caller-supplied arg wins; otherwise the field falls back to the element's own
      # value. `args.key?` so an explicit nil still counts as supplied.
      def resolve_element_append_source(source, element, args)
        return source unless source.is_a?(Symbol)
        return args[source] if args.key?(source)

        element[source]
      end

      def appended_to_element(aggregate, entity, element, mutation, args)
        fields       = mutation.source.transform_values { |source| resolve_element_append_source(source, element, args) }
        element_type = entity.attribute(mutation.target)&.type
        value_object = aggregate.value_object(element_type)
        value_object&.attributes&.each do |attribute|
          fields[attribute.name] = Value.scalar(fields[attribute.name]) if fields[attribute.name].is_a?(Value)
        end
        appended =
          if value_object
            Value.build(value_object, fields, aggregate)
          else
            # `entity.entities`, not `aggregate.entities` — a nested piece is a child of
            # the owning entity, not of the root aggregate.
            nested_entity = entity.entities.find { |piece| piece.hecks_name == element_type.to_s }
            if nested_entity
              check_entity_collision(entity, nested_entity, element[mutation.target], fields)
              fill_declared_defaults(aggregate, nested_entity, fields)
            else
              fields
            end
          end
        Freezer.deep(Array(element[mutation.target]) + [appended])
      end

      # Fills every declared attribute `fields` does not already hold with its own
      # default (Instance.default_for), matching a freshly created aggregate's own
      # per-attribute defaults. Additive only: an existing key in `fields` is kept.
      def fill_declared_defaults(aggregate, entity, fields)
        entity.attributes.each do |attribute|
          next if fields.key?(attribute.name)

          fields[attribute.name] = attribute.list? ? Freezer.deep([]) : Instance.default_for(aggregate, attribute)
        end
        fields
      end

      # Removes the element matching by value, or by identity for entity-typed lists.
      def removed_from_element(rules, aggregate, entity, element, mutation, args)
        value     = rules.resolve_source(mutation.source, args)
        attribute = entity.attribute(mutation.target)
        value     = Value.for_attribute(aggregate, attribute, value) if attribute
        Array(element[mutation.target]).reject { |candidate| list_element_match?(aggregate, attribute, candidate, value) }
      end

      # The match rule `remove:` uses against one stored list element. Whole-value
      # equality for a non-entity-typed list; for an entity-typed one, matches by its
      # single identity head (a composite or absent identity never matches).
      def list_element_match?(aggregate, attribute, element, value)
        entity = attribute&.list? ? Value.find_entity(aggregate, attribute.type.to_s) : nil
        return element == value unless entity

        head = entity.identity_heads.one? ? entity.identity_heads.first : nil
        return false unless head

        element.is_a?(Hash) && element[head] == value
      end

      # Refuses a caller-supplied or composite identity that already names an element
      # in `current`. Shared by the aggregate-owned and entity-owned append paths so
      # neither reimplements the check. `owner` is named in the refusal only.
      def check_entity_collision(owner, entity, current, fields)
        heads = entity.identity_heads
        return if heads.empty?

        collision = Array(current).find { |element| heads.all? { |head| element[head] == fields[head] } }
        return unless collision

        raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "entity_duplicate",
                                                        entity: entity.hecks_name, aggregate: owner.hecks_name,
                                                        identity: Identity.reading(entity),
                                                        offered: heads.map { |head| Rendering.describe(fields[head]) }))
      end
    end
  end
end
