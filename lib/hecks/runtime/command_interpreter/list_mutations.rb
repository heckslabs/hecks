require_relative "../value"
require_relative "../entity_element"

module Hecks
  module Runtime
    class CommandInterpreter
      # The list-valued mutations: `append` builds one element, `remove` drops the matching ones.
      # Mixed into {MutationApplier}.
      module ListMutations
        private

        # A caller-supplied arg wins; otherwise the field falls back to the instance's own
        # value. `args.key?` so an explicit nil still counts as supplied.
        def resolve_append_source(source, instance, args)
          # `state(:field)` reads the record's own value, never an argument.
          return instance[source.name] if source.is_a?(StateRef)
          return source unless source.is_a?(Symbol)
          return args[source] if args.key?(source)

          instance[source]
        end

        def appended(instance, aggregate, mutation, args)
          fields       = mutation.source.transform_values { |source| resolve_append_source(source, instance, args) }
          element_type = aggregate.attribute(mutation.target)&.type
          element      = appended_element(aggregate, element_type, instance[mutation.target], fields)

          # Frozen so a caller cannot push into the aggregate's state after dispatch.
          Freezer.deep(Array(instance[mutation.target]) + [element])
        end

        # The one element an append adds: a value object, or an entity with its own identity.
        def appended_element(aggregate, element_type, current, fields)
          value_object = aggregate.value_object(element_type)
          unwrap_single_fields(value_object, fields)
          return Value.build(value_object, fields, aggregate) if value_object

          entity_element(aggregate, element_type, current, fields)
        end

        # A single-field value unwraps to its scalar; a multi-field one passes through whole.
        def unwrap_single_fields(value_object, fields)
          value_object&.attributes&.each do |attribute|
            held = fields[attribute.name]
            fields[attribute.name] = Value.scalar(held) if held.is_a?(Value) && held.to_h.size == 1
          end
        end

        # Removes the element matching by value, or by identity for entity-typed lists.
        def removed(instance, aggregate, mutation, args)
          value     = @rules.resolve_source(mutation.source, args)
          attribute = aggregate.attribute(mutation.target)
          value     = Value.for_attribute(aggregate, attribute, value) if attribute
          Array(instance[mutation.target]).reject do |element|
            EntityElement.list_element_match?(aggregate, attribute, element, value)
          end
        end

        def entity_element(aggregate, element_type, current, fields)
          entity = aggregate.entities.find { |piece| piece.hecks_name == element_type.to_s }
          return fields unless entity

          coerce_entity_fields(aggregate, entity, fields)
          assign_entity_identity(aggregate, entity, current, fields)
          fields[entity.lifecycle.field] ||= entity.lifecycle.default if entity.lifecycle
          # Fill declared defaults for attributes the append mapping did not touch, shared with
          # EntityElement so both entity-creation paths agree on what "the default" means.
          EntityElement.fill_declared_defaults(aggregate, entity, fields)
        end

        def coerce_entity_fields(aggregate, entity, fields)
          entity.attributes.each do |attribute|
            next unless fields.key?(attribute.name)

            fields[attribute.name] = Value.for_attribute(aggregate, attribute, fields[attribute.name])
          end
        end

        # Mints the entity's identity when the append left it out; otherwise the entity-collision
        # guard (shared with EntityElement#appended_to_element) checks the one given.
        def assign_entity_identity(aggregate, entity, current, fields)
          if entity.identified_by && !fields.key?(entity.identified_by)
            attribute = entity.attribute(entity.identified_by)
            fields[entity.identified_by] = Value.from_identifier(aggregate, attribute, next_identity(current, entity))
          else
            EntityElement.check_entity_collision(aggregate, entity, current, fields)
          end
        end

        # One past the highest identity held, not `size + 1`, which repeats one after a shrink.
        def next_identity(current, entity)
          held = Array(current).map { |element| Value.scalar(element[entity.identified_by]).to_i }
          held.max.to_i + 1
        end
      end
    end
  end
end
