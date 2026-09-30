require_relative "../value"
require_relative "../entity_element"

module Hecks
  module Runtime
    class CommandInterpreter
      # Applies a command's declared mutations (set, append, remove, arithmetic) to an instance.
      module MutationApplier
        private

        def assign_creation_attributes(instance, aggregate, command, args)
          command.attributes.each do |attr|
            next unless aggregate.attribute(attr.name)
            next unless args.key?(attr.name)

            instance[attr.name] = Value.for(aggregate, attr.name, args[attr.name])
          end
        end

        # Applies one mutation: sources read `pre` (pre-dispatch state), targets write `instance`.
        # rubocop:disable Lint/DuplicateBranch -- :delegate and :corrects
        # both no-op here, for unrelated reasons; merging would blur that.
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
        def apply(instance, aggregate, mutation, args, pre = instance)
          case mutation.op
          when :set
            value = if mutation.source.is_a?(StateRef)
                      pre[mutation.source.name]
                    else
                      @rules.resolve_source(mutation.source,
                                            args)
                    end
            # A plain `sets` of a list takes the whole list; only `append:` and `remove:` take
            # one element.
            list_attribute = aggregate.attribute(mutation.target)
            Value.refuse_scalar_list(aggregate, list_attribute, value) if list_attribute && !mutation.source.is_a?(StateRef)
            instance[mutation.target] = Value.for(aggregate, mutation.target, value)
          when :append
            instance[mutation.target] = appended(pre, aggregate, mutation, args)
          when :increment, :decrement
            amount = @rules.resolve_source(mutation.source, args)
            attribute = aggregate.attribute(mutation.target)
            current   = pre[mutation.target]
            # Wrap `amount` only when `current` is already a Value (see #rewrap_arithmetic_result).
            amount = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
            result = @rules.arithmetic(current, amount, mutation.target, @rules.sign_of(mutation.op))
            instance[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
          # Removes a list element by value, the counterpart to append.
          when :remove
            instance[mutation.target] = removed(pre, aggregate, mutation, args)
          # Scales the current value; the counterpart to clamp below.
          when :multiply
            amount = @rules.resolve_source(mutation.source, args)
            attribute = aggregate.attribute(mutation.target)
            current   = pre[mutation.target]
            amount = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
            result = @rules.multiply(current, amount, mutation.target)
            instance[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
          # Bounds the current value into [min, max]; the source is a literal pair, read as is.
          when :clamp
            instance[mutation.target] = @rules.clamp(pre[mutation.target], mutation.source, mutation.target)
          # `delegates_to`: a no-op here; CommandInterpreter#step_delegate_to_entity applies it.
          when :delegate
            nil
          # `corrects`: a no-op here; its target event is checked up front by
          # CommandRules::Admissibility#enforce_correction_target.
          when :corrects
            nil
          else
            # Backstop: an unhandled op must refuse, not silently apply nothing.
            raise Runtime::WiringError, "no mutation applier handles :#{mutation.op} — add one before declaring it"
          end
        end
        # rubocop:enable Lint/DuplicateBranch
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

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
          value_object = aggregate.value_object(element_type)
          value_object&.attributes&.each do |attribute|
            held = fields[attribute.name]
            # A single-field value unwraps to its scalar; a multi-field one passes through whole.
            fields[attribute.name] = Value.scalar(held) if held.is_a?(Value) && held.to_h.size == 1
          end
          element = if value_object
                      Value.build(value_object, fields,
                                  aggregate)
                    else
                      entity_element(aggregate, element_type, instance[mutation.target],
                                     fields)
                    end

          # Frozen so a caller cannot push into the aggregate's state after dispatch.
          Freezer.deep(Array(instance[mutation.target]) + [element])
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

        # Wraps a plain-Numeric arithmetic result back into the attribute's Value type.
        # Skipped when `current` was already a Value, since the Value path returns one.
        def rewrap_arithmetic_result(aggregate, attribute, current, result)
          return result if current.is_a?(Value) || attribute.nil? || result.is_a?(Value)

          Value.for_attribute(aggregate, attribute, result)
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
            fields[entity.identified_by] = Value.from_identifier(aggregate, attribute, next_identity(current, entity))
          else
            EntityElement.check_entity_collision(aggregate, entity, current, fields)
          end
          fields[entity.lifecycle.field] ||= entity.lifecycle.default if entity.lifecycle
          # Fill declared defaults for attributes the append mapping did not touch, shared with
          # EntityElement so both entity-creation paths agree on what "the default" means.
          EntityElement.fill_declared_defaults(aggregate, entity, fields)
        end

        # One past the highest identity held, not `size + 1`, which repeats one after a shrink.
        def next_identity(current, entity)
          held = Array(current).map { |element| Value.scalar(element[entity.identified_by]).to_i }
          held.max.to_i + 1
        end

        # The entity-collision guard is shared with EntityElement#appended_to_element.
      end
    end
  end
end
