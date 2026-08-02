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
          end
        end

        def appended(instance, aggregate, mutation, args)
          fields       = mutation.source.transform_values { |source| source.is_a?(Symbol) ? args[source] : source }
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
