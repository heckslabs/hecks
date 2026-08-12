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
            current   = instance[mutation.target]
            # Vendored fix, not (yet) upstream hecksagain (migration plan
            # task 9): see #rewrap_arithmetic_result's own comment below
            # -- `amount` is wrapped ONLY when `current` already is, not
            # merely because the target attribute exists.
            amount = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
            result = @rules.arithmetic(current, amount, mutation.target, @rules.sign_of(mutation.op))
            instance[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
          # Vendored addition, not (yet) upstream hecksagain (migration
          # plan task 4): remove -- the list-removal counterpart to
          # append, matching an element by value (plan.bluebook's
          # RemoveDependency/DeactivateSprint: "a concurrent Add can
          # never be lost").
          when :remove
            instance[mutation.target] = removed(instance, aggregate, mutation, args)
          # Vendored addition, not (yet) upstream hecksagain (migration
          # plan task 4, i106): multiply/clamp, the scale/bound pair
          # alongside increment/decrement's add/subtract pair -- see
          # CommandRules::Arithmetic#multiply/#clamp's own comments.
          when :multiply
            amount = @rules.resolve_source(mutation.source, args)
            attribute = aggregate.attribute(mutation.target)
            current   = instance[mutation.target]
            amount = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
            result = @rules.multiply(current, amount, mutation.target)
            instance[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
          # Vendored addition, not (yet) upstream hecksagain (migration
          # plan task 4, i106): clamp -- bounds the current value into
          # [min, max]. mutation.source is always a literal [min, max]
          # pair, never an argument reference -- resolve_source would be
          # a no-op for an Array (it only special-cases Symbol), so it's
          # read straight.
          when :clamp
            instance[mutation.target] = @rules.clamp(instance[mutation.target], mutation.source, mutation.target)
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

        # Vendored fix, not (yet) upstream hecksagain (migration plan
        # task 9): #apply's `:increment`/`:decrement`/`:multiply`
        # branches used to wrap `amount` into a `Value` unconditionally
        # whenever the target attribute existed, never checking whether
        # `current` (the field's OWN existing value, read straight off
        # `instance[mutation.target]`) was ALSO wrapped -- the two sides
        # of the same arithmetic call could disagree on Value-ness. On a
        # PHANTOM-CREATED field this is the common case, not an edge
        # one: `Instance.defaults`/`#default_for` leaves a VO-typed
        # attribute with no declared `default:` genuinely absent (nil),
        # and `CommandRules::Arithmetic#arithmetic`/`#multiply`'s own
        # `current ||= 0` then turns that nil into a RAW, unwrapped
        # Integer `0` -- so `current.is_a?(Value) && amount.is_a?(Value)`
        # read false even though `amount` (correctly wrapped by the old
        # unconditional line) genuinely held a valid, correctly-typed
        # number, and the primitive path's `unless amount.is_a?(Numeric)`
        # guard refused it as a TYPE MISMATCH the caller never made --
        # an artifact of this method's own asymmetric wrapping, not bad
        # input.
        #
        # Fixed at the call site (above) by wrapping `amount` ONLY when
        # `current` is ALREADY a `Value` -- so an established VO-typed
        # field (a multi-field Money balance, say, already hydrated from
        # a prior save) keeps going through
        # `Arithmetic#arithmetic_value_object` exactly as before (the
        # "already-Value-wrapped field still mutates correctly" case
        # this fix must not regress), while a phantom field's raw
        # `current` and raw `amount` both take the plain-Numeric path
        # together. This method closes the other half: the plain-Numeric
        # path returns a bare Ruby number, and if the attribute is
        # itself VO-typed (the norm), that raw result needs the SAME
        # wrap `:set` already gives its own resolved value (`Value.for`)
        # before it's stored, so a field's stored shape doesn't depend
        # on which dispatch happened to mutate it first. A no-op
        # whenever `current` was already a Value (the VO branch already
        # returns one) or the mutation targets no declared attribute at
        # all.
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
            fields[entity.identified_by] = Value.from_identifier(aggregate, attribute, Array(current).size + 1)
          end
          fields[entity.lifecycle.field] ||= entity.lifecycle.default if entity.lifecycle
          fields
        end
      end
    end
  end
end
