module Hecks
  module Fuzzing
    module Properties
      # Independent recomputations of what each mutation op leaves behind, for
      # `DispatchAndMutations#mutations_match_recompute` to compare against the real dispatch.
      module MutationRecompute
        # What a recomputation needs of the step it re-derives.
        #
        # `before` is the entity's state before the dispatch; `owner` is the construct declaring
        # the mutated attribute, the root aggregate unless a dot-shaped command names an entity.
        Context = Struct.new(:aggregate, :command, :owner, :before, :args)

        # Dispatches to the recompute rule for `mutation.op`.
        #
        # @param mutation [Object] the mutation the command declares
        # @param current [Object] the mutated attribute's value before the dispatch
        # @param context [Context] the step being re-derived
        # @return [Object, Symbol] the recomputed after-value, or `:unrecomputable`
        def recompute_mutation(mutation, current, context)
          case mutation.op
          when :append   then recompute_append(current, mutation.source, context, mutation.target)
          when :remove   then recompute_remove(current, mutation.source, context.args)
          when :multiply then recompute_multiply(current, resolve_mutation_source(mutation.source, context.args))
          when :clamp    then recompute_clamp(current, mutation.source)
          when :set      then recompute_set(mutation.source, context, mutation.target)
          end
        end

        # Re-derives the `:set` branch of `EntityElement#apply_to_element`. The
        # attribute comes from `owner`, not the root aggregate, which would leave a
        # nested entity's value uncoerced and disagree with the real after-state.
        # Any raise means the raw material was wrong, so the result is `:unrecomputable`.
        def recompute_set(source, context, target)
          raw = resolve_mutation_source(source, context.args)
          attribute = context.owner&.attribute(target)
          coerced = attribute ? Runtime::Value.for_attribute(context.aggregate, attribute, raw) : raw
          Runtime::Value.materialize(coerced)
        rescue StandardError
          :unrecomputable
        end

        # Re-derives `EntityElement#appended_to_element`: each field resolves from a
        # caller arg (coerced as `Interpreting#coerce_declared_arguments` does) or from
        # the entity's current field (already materialized), then the element is appended.
        # A nested-entity element also gets its declared defaults.
        def recompute_append(current, source_map, context, target = nil)
          fields = source_map.transform_values { |source| resolve_mutation_append_field(source, context) }
          fill_recompute_declared_defaults(context, target, fields)
          Array(current) + [symbolize_deep(fields)]
        end

        # Fills defaults for a nested-entity element via `Instance.default_for`, which is
        # independently tested. No-op unless `target` names an entity under `owner`
        # (`owner.entities`, not `aggregate.entities`).
        #
        # A value-object element type (the more common shape: `list_of` a plain composite,
        # not a nested entity) defaults the other way real dispatch does — through
        # `Runtime::Value.apply_defaults`, the exact primitive `EntityElement#appended_to_
        # element`'s own `Value.build` call uses. Without this branch, a caller-omitted,
        # VO-declared `default:` field is left out of the recomputed element entirely,
        # disagreeing with real dispatch's fully-defaulted one.
        def fill_recompute_declared_defaults(context, target, fields)
          element_type = target && context.owner&.attribute(target)&.type
          return fields unless element_type

          entity = context.owner.entities.find { |piece| piece.hecks_name == element_type.to_s }
          return fill_entity_defaults(context.aggregate, entity, fields) if entity

          fill_value_object_defaults(context.aggregate, element_type, fields)
        end

        def fill_entity_defaults(aggregate, entity, fields)
          entity.attributes.each do |attribute|
            next if fields.key?(attribute.name)

            fields[attribute.name] = attribute.list? ? [] : Runtime::Instance.default_for(aggregate, attribute)
          end
          fields
        end

        def fill_value_object_defaults(aggregate, element_type, fields)
          value_object = aggregate.value_object(element_type)
          value_object ? Runtime::Value.apply_defaults(value_object, fields) : fields
        end

        # Resolves one appended field's value from its declared source.
        def resolve_mutation_append_field(source, context)
          return source unless source.is_a?(Symbol)
          return context.before[source] unless context.args.key?(source)

          coerce_recompute_append_arg(context, source, context.args[source])
        end

        # Coerces a raw arg only when `source` is a declared attribute of the command,
        # as a real dispatch does. Materialized so the comparison is plain data on both sides.
        def coerce_recompute_append_arg(context, source, raw)
          attribute = context.command.attribute(source)
          return raw unless attribute

          Runtime::Value.materialize(Runtime::Value.for_attribute(context.aggregate, attribute, raw, argument: true))
        end

        # Re-derives `MutationApplier#removed`: removes every value-equal element.
        # `Value.materialize` first: once `args` arrives normalized (replay.rb's
        # `build_mutation_trace`), a composite `remove:` source is already a built
        # `Runtime::Value` with its own declared defaults filled — comparing it
        # unmaterialized against `current`'s plain Hashes would never match, wrongly
        # keeping an element real dispatch correctly removed.
        def recompute_remove(current, source, args)
          target = symbolize_deep(Runtime::Value.materialize(resolve_mutation_source(source, args)))
          Array(current).reject { |element| symbolize_deep(element) == target }
        end

        # Re-derives `CommandRules::Arithmetic#multiply` on plain data: a Hash with one
        # numeric field scales that field, a bare Numeric scales itself. A nil
        # `current` is treated as 0.
        def recompute_multiply(current, amount)
          return :unrecomputable unless amount.is_a?(Numeric)

          apply_to_number(current) { |number| number * amount }
        end

        # Re-derives `CommandRules::Arithmetic#clamp` like #recompute_multiply. The
        # source is always a literal `[min, max]`, never an argument reference.
        def recompute_clamp(current, bounds)
          return :unrecomputable unless bounds.is_a?(Array) && bounds.size == 2

          min, max = bounds
          apply_to_number(current) { |number| number.clamp(min, max) }
        end

        # Yields a bare Numeric, or the first numeric field of a Hash, and puts the result back.
        # Anything else, or a Hash with no numeric field, is `:unrecomputable`; nil counts as 0.
        def apply_to_number(current)
          current ||= 0
          return yield(current) if current.is_a?(Numeric)
          return :unrecomputable unless current.is_a?(Hash)

          field = current.keys.find { |f| current[f].is_a?(Numeric) }
          return :unrecomputable unless field

          current.merge(field => yield(current[field]))
        end

        # A mutation source is an argument name (Symbol) or a literal.
        def resolve_mutation_source(source, args)
          source.is_a?(Symbol) ? args[source] : source
        end

        # Symbolizes hash keys recursively. Generated args carry string keys while
        # materialized trace state carries symbols, and `Hash#==` would otherwise differ.
        def symbolize_deep(value)
          case value
          when Hash  then value.to_h { |key, val| [key.to_sym, symbolize_deep(val)] }
          when Array then value.map { |val| symbolize_deep(val) }
          else value
          end
        end
      end
    end
  end
end
