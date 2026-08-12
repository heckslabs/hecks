require_relative "../value"

module Hecksagain
  module Runtime
    class CommandInterpreter
      # How a command's declared mutations land on the instance in hand —
      # set, append (with value-object or entity elements), and the
      # arithmetic pair.
      module MutationApplier
        private

        def assign_creation_attributes(instance, aggregate, command, args)
          command.attributes.each do |attr|
            next unless aggregate.attribute(attr.name)
            next unless args.key?(attr.name)

            instance[attr.name] = Value.for(aggregate, attr.name, args[attr.name])
          end
        end

        def apply(instance, aggregate, mutation, args)
          case mutation.op
          when :set
            value = @rules.resolve_source(mutation.source, args)
            instance[mutation.target] = Value.for(aggregate, mutation.target, value)
          when :append
            instance[mutation.target] = appended(instance, aggregate, mutation, args)
          when :increment, :decrement
            amount = @rules.resolve_source(mutation.source, args)
            attribute = aggregate.attribute(mutation.target)
            amount = Value.for_attribute(aggregate, attribute, amount) if attribute
            instance[mutation.target] = @rules.arithmetic(
              instance[mutation.target],
              amount,
              mutation.target,
              @rules.sign_of(mutation.op)
            )
          # Vendored addition, not (yet) upstream hecksagain (migration
          # plan task 4): remove -- the list-removal counterpart to
          # append, matching an element by value (plan.bluebook's
          # RemoveDependency/DeactivateSprint: "a concurrent Add can
          # never be lost").
          when :remove
            instance[mutation.target] = removed(instance, aggregate, mutation, args)
          # Vendored addition, not (yet) upstream hecksagain (migration
          # plan task 4, i106): multiply -- the scale counterpart to
          # increment/decrement's add/subtract -- see
          # CommandRules::Arithmetic#multiply's own comment. Same
          # amount-wrapping shape increment/decrement already use above
          # (the shared Value-wrap asymmetry across all three is item 17's
          # own fix, not repeated here).
          when :multiply
            amount = @rules.resolve_source(mutation.source, args)
            attribute = aggregate.attribute(mutation.target)
            amount = Value.for_attribute(aggregate, attribute, amount) if attribute
            instance[mutation.target] = @rules.multiply(instance[mutation.target], amount, mutation.target)
          end
        end

        # A CALLER-SUPPLIED ARG, FIRST -- an append's own field can also
        # name something the SUBJECT ALREADY KNOWS about itself, falling
        # back to the AGGREGATE'S OWN CURRENT FIELD when it isn't one — a
        # caller appending at the end without computing or supplying a
        # position (`position: :next_position`, a field the command never
        # declares as an argument at all). `args.key?`, not a truthiness
        # check on the value — an explicitly-nil argument still counts as
        # "the caller named it," same distinction `assign_creation_attributes`
        # already draws.
        #
        # Extracted to its own method (pure refactor, ternary -> early
        # return, no behavior change) alongside `remove`'s own addition
        # below, purely for readability at this point in the file.
        def resolve_append_source(source, instance, args)
          return source unless source.is_a?(Symbol)
          return args[source] if args.key?(source)

          instance[source]
        end

        def appended(instance, aggregate, mutation, args)
          fields       = mutation.source.transform_values { |source| resolve_append_source(source, instance, args) }
          element_type = aggregate.attribute(mutation.target)&.type
          value_object = aggregate.value_object(element_type)
          if value_object
            value_object.attributes.each do |attribute|
              fields[attribute.name] = Value.scalar(fields[attribute.name]) if fields[attribute.name].is_a?(Value)
            end
          end
          element      = value_object ? Value.build(value_object, fields) : entity_element(aggregate, element_type, instance[mutation.target], fields)

          Array(instance[mutation.target]) + [element]
        end

        # Vendored addition, not (yet) upstream hecksagain (migration plan
        # task 4): the removal counterpart to #appended -- matches by
        # VALUE EQUALITY, element-wise, no read-modify-write (plan.
        # bluebook's own words: "so a concurrent Add can never be lost").
        # `mutation.source` is a single field reference (`:dependency`),
        # unlike append's field-map -- resolved and Value-coerced the
        # SAME way increment/decrement already coerce their own amount,
        # so the comparison is against a like-shaped Value, not a raw
        # scalar against a wrapped one.
        def removed(instance, aggregate, mutation, args)
          value     = @rules.resolve_source(mutation.source, args)
          attribute = aggregate.attribute(mutation.target)
          value     = Value.for_attribute(aggregate, attribute, value) if attribute
          Array(instance[mutation.target]).reject { |element| element == value }
        end

        def entity_element(aggregate, element_type, current, fields)
          entity = aggregate.entities.find { |piece| piece.hecks_name == element_type.to_s }
          return fields unless entity

          entity.attributes.each do |attribute|
            next unless fields.key?(attribute.name)

            fields[attribute.name] = Value.for_attribute(aggregate, attribute, fields[attribute.name])
          end
          if entity.identified_by && !fields.key?(entity.identified_by)
            attribute = entity.attribute(entity.identified_by)
            fields[entity.identified_by] = Value.from_identifier(aggregate, attribute, Array(current).size + 1)
          end
          fields[entity.lifecycle.field] ||= entity.lifecycle.default if entity.lifecycle
          fields
        end
      end
    end
  end
end
