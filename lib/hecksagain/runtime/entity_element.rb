require_relative "../naming"
require_relative "../freezer"
require_relative "value"
require_relative "refusal_wording"
require_relative "errors"
require_relative "identity"

module Hecksagain
  module Runtime
    # ONE ENTITY ELEMENT, LOCATED AND MUTATED — the walk-and-write half of
    # dispatching into a piece an aggregate holds, factored out of
    # `EntityInterpreter` so a SECOND caller (`CommandInterpreter`'s own
    # `delegate_to_entity` step, added alongside this) can locate and mutate
    # the SAME element the same way, against an aggregate record it already
    # holds in memory rather than one freshly loaded from a repository.
    # `EntityInterpreter` keeps its own dispatch order and Context; this is
    # the part underneath that both now share, so it exists in exactly one
    # place rather than two that could only ever drift (the same reasoning
    # `Runtime::Identity`'s own header gives for the join/dig/reading trio
    # it centralizes).
    module EntityElement
      module_function

      # ONE HOP PER CHAIN ENTRY. `container` starts as the aggregate record
      # (`instance`) and becomes each just-located element in turn.
      def locate_chain(root_aggregate, chain, instance, args, command_name)
        container = instance
        owner     = root_aggregate
        chain.each do |entity|
          container = element_of(root_aggregate, owner, entity, command_name, container, args)
          owner = entity
        end
        container
      end

      # ONE ELEMENT, MATCHED ON EVERY PART OF ITS IDENTITY.
      def element_of(root_aggregate, owner, entity, command_name, container, args)
        entity_name = entity.hecks_name
        list_attr = owner.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_holds_no_list",
                                                             aggregate: owner.hecks_name, entity: entity_name))

        wants = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          raw  = args[head] ||
                 raise(NotFound, RefusalWording.render("NotFound", "entity_element_no_identity",
                                                       command: command_name, entity: entity_name,
                                                       identity: Identity.reading(entity)))

          [head, path, Value.for_attribute(root_aggregate, entity.attribute(head), raw)]
        end

        original = Array(container[list_attr.name])
        position = original.find_index { |el| wants.all? { |head, _path, want| el[head] == want } }
        unless position
          raise NotFound, RefusalWording.render(
            "NotFound", "entity_element_missing",
            entity: entity_name, identity: Identity.reading(entity),
            wants: wants.map { |_h, path, want| Identity.scalar(path, want) }.join(", "),
            aggregate: owner.hecks_name,
            parent_id: container.respond_to?(:id) ? container.id.inspect : Rendering.describe(container)
          )
        end

        # Copy-on-write, same as before this file existed: nothing aliased
        # with the adapter's own record survives a refusal, and the copy
        # written into `container` is what a later hop (or the caller's
        # own `step_save`) actually persists.
        copied  = original.dup
        element = copied[position].dup
        copied[position] = element
        container[list_attr.name] = copied
        element
      end

      # THE ELEMENT'S OWN IDENTITY, joined from its parts.
      def element_identity(entity, element)
        parts = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          Identity.scalar(path, element[head])
        end

        Naming.identity(parts)
      end

      # `rules` (a `CommandRules` instance) does the arithmetic/coercion
      # this needs (`resolve_source`, `arithmetic`, `sign_of`, `multiply`,
      # `clamp`) — passed explicitly rather than closed over, since this
      # module has no instance of its own to hold one.
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
          raise WiringError, "no entity mutation applier handles :#{mutation.op} — add one before declaring it"
        end
      end

      def rewrap_arithmetic_result(aggregate, attribute, current, result)
        return result if current.is_a?(Value) || attribute.nil? || result.is_a?(Value)

        Value.for_attribute(aggregate, attribute, result)
      end

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
        appended = value_object ? Value.build(value_object, fields, aggregate) : fields
        Freezer.deep(Array(element[mutation.target]) + [appended])
      end

      def removed_from_element(rules, aggregate, entity, element, mutation, args)
        value     = rules.resolve_source(mutation.source, args)
        attribute = entity.attribute(mutation.target)
        value     = Value.for_attribute(aggregate, attribute, value) if attribute
        Array(element[mutation.target]).reject { |candidate| candidate == value }
      end
    end
  end
end
