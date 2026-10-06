require_relative "../value"
require_relative "../entity_element"
require_relative "list_mutations"

module Hecks
  module Runtime
    class CommandInterpreter
      # Applies a command's declared mutations (set, append, remove, arithmetic) to an instance.
      module MutationApplier
        include ListMutations

        # The handler each mutation op dispatches to. `delegate` and `corrects` both apply nothing
        # here, for unrelated reasons: `delegates_to` is applied by
        # CommandInterpreter#step_delegate_to_entity, and `corrects` has its target event checked
        # up front by CommandRules::Admissibility#enforce_correction_target.
        OP_HANDLERS = {
          set:       :apply_set,
          append:    :apply_append,
          increment: :apply_arithmetic,
          decrement: :apply_arithmetic,
          remove:    :apply_remove,
          multiply:  :apply_multiply,
          clamp:     :apply_clamp,
          delegate:  :apply_nothing,
          corrects:  :apply_nothing
        }.freeze

        private

        def assign_creation_attributes(instance, aggregate, command, args)
          command.attributes.each do |attr|
            next unless aggregate.attribute(attr.name)
            next unless args.key?(attr.name)

            instance[attr.name] = Value.for(aggregate, attr.name, args[attr.name])
          end
        end

        # Applies one mutation: sources read `pre` (pre-dispatch state), targets write `instance`.
        def apply(instance, aggregate, mutation, args, pre = instance)
          handler = OP_HANDLERS.fetch(mutation.op) do
            # Backstop: an unhandled op must refuse, not silently apply nothing.
            raise Runtime::WiringError, "no mutation applier handles :#{mutation.op} — add one before declaring it"
          end
          send(handler, instance, aggregate, mutation, args, pre)
        end

        def apply_set(instance, aggregate, mutation, args, pre)
          from_state = mutation.source.is_a?(StateRef)
          value = from_state ? pre[mutation.source.name] : @rules.resolve_source(mutation.source, args)
          # A plain `sets` of a list takes the whole list; only `append:` and `remove:` take
          # one element.
          list_attribute = aggregate.attribute(mutation.target)
          Value.refuse_scalar_list(aggregate, list_attribute, value) if list_attribute && !from_state
          instance[mutation.target] = Value.for(aggregate, mutation.target, value)
        end

        def apply_append(instance, aggregate, mutation, args, pre)
          instance[mutation.target] = appended(pre, aggregate, mutation, args)
        end

        # Removes a list element by value, the counterpart to append.
        def apply_remove(instance, aggregate, mutation, args, pre)
          instance[mutation.target] = removed(pre, aggregate, mutation, args)
        end

        def apply_arithmetic(instance, aggregate, mutation, args, pre)
          apply_numeric(instance, aggregate, mutation, args, pre) do |current, amount|
            @rules.arithmetic(current, amount, mutation.target, @rules.sign_of(mutation.op))
          end
        end

        # Scales the current value; the counterpart to clamp below.
        def apply_multiply(instance, aggregate, mutation, args, pre)
          apply_numeric(instance, aggregate, mutation, args, pre) do |current, amount|
            @rules.multiply(current, amount, mutation.target)
          end
        end

        # Bounds the current value into [min, max]; the source is a literal pair, read as is.
        def apply_clamp(instance, _aggregate, mutation, _args, pre)
          instance[mutation.target] = @rules.clamp(pre[mutation.target], mutation.source, mutation.target)
        end

        def apply_nothing(_instance, _aggregate, _mutation, _args, _pre)
          nil
        end

        # Resolves the amount, lets the block combine it with the current value, and stores the
        # result back as the attribute's own type.
        def apply_numeric(instance, aggregate, mutation, args, pre)
          amount    = @rules.resolve_source(mutation.source, args)
          attribute = aggregate.attribute(mutation.target)
          current   = pre[mutation.target]
          # Wrap `amount` only when `current` is already a Value (see #rewrap_arithmetic_result).
          amount = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result = yield(current, amount)
          instance[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        end

        # Wraps a plain-Numeric arithmetic result back into the attribute's Value type.
        # Skipped when `current` was already a Value, since the Value path returns one.
        def rewrap_arithmetic_result(aggregate, attribute, current, result)
          return result if current.is_a?(Value) || attribute.nil? || result.is_a?(Value)

          Value.for_attribute(aggregate, attribute, result)
        end
      end
    end
  end
end
