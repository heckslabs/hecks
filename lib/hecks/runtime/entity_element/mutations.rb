require_relative "../../freezer"
require_relative "../errors"
require_relative "../value"

module Hecks
  module Runtime
    module EntityElement
      # Applies a declared mutation to an entity element, in place. Extended onto
      # {EntityElement}.
      module Mutations
        # One mutation against one element: the rules engine, the aggregate and entity it belongs
        # to, the element written, the mutation, the dispatch's arguments, and `pre`, the element
        # as it stood before this command, which every read goes through.
        Application = Struct.new(:rules, :aggregate, :entity, :element, :mutation, :args, :pre) do
          def target = mutation.target
          def attribute = entity.attribute(target)
          def source_value = rules.resolve_source(mutation.source, args)
          def current = pre[target]
        end

        # The handler each mutation op dispatches to. `corrects` applies nothing here: the target
        # event was already checked by EntityInterpreter#step_enforce_givens.
        OP_HANDLERS = {
          set:       :apply_set,
          append:    :apply_append,
          remove:    :apply_remove,
          increment: :apply_arithmetic,
          decrement: :apply_arithmetic,
          multiply:  :apply_multiply,
          clamp:     :apply_clamp,
          corrects:  :apply_nothing
        }.freeze

        # Applies one declared mutation to an entity element, in place. `pre` is the
        # element as it stood before this command: every read goes through it, every
        # write lands on `element`.
        # rubocop:disable-next Metrics/ParameterLists -- the positional signature callers (and specs) wrap
        def apply_to_element(rules, aggregate, entity, element, mutation, args, pre = element)
          handler = OP_HANDLERS.fetch(mutation.op) do
            # Backstop: an unhandled op must refuse, not silently apply nothing.
            raise WiringError, "no entity mutation applier handles :#{mutation.op} — add one before declaring it"
          end
          send(handler, Application.new(rules, aggregate, entity, element, mutation, args, pre))
        end

        # A caller-supplied arg wins; otherwise the field falls back to the element's own
        # value. `args.key?` so an explicit nil still counts as supplied.
        def resolve_element_append_source(source, element, args)
          return source unless source.is_a?(Symbol)
          return args[source] if args.key?(source)

          element[source]
        end

        def appended_to_element(aggregate, entity, element, mutation, args)
          fields  = mutation.source.transform_values { |source| resolve_element_append_source(source, element, args) }
          current = element[mutation.target]
          Freezer.deep(Array(current) + [appended_element(aggregate, entity, mutation, current, fields)])
        end

        # Removes the element matching by value, or by identity for entity-typed lists.
        def removed_from_element(app)
          attribute = app.attribute
          value     = app.source_value
          value     = Value.for_attribute(app.aggregate, attribute, value) if attribute
          Array(app.pre[app.target]).reject { |candidate| list_element_match?(app.aggregate, attribute, candidate, value) }
        end

        # Rewraps a plain-Numeric arithmetic result into the attribute's own Value type.
        # A no-op when `current` was already a Value, or the mutation targets no attribute.
        def rewrap_arithmetic_result(aggregate, attribute, current, result)
          return result if current.is_a?(Value) || attribute.nil? || result.is_a?(Value)

          Value.for_attribute(aggregate, attribute, result)
        end

        private

        def apply_set(app)
          value = app.source_value
          attribute = app.attribute
          app.element[app.target] = attribute ? Value.for_attribute(app.aggregate, attribute, value) : value
        end

        def apply_append(app)
          app.element[app.target] = appended_to_element(app.aggregate, app.entity, app.pre, app.mutation, app.args)
        end

        def apply_remove(app)
          app.element[app.target] = removed_from_element(app)
        end

        def apply_arithmetic(app)
          apply_numeric(app) do |current, amount|
            app.rules.arithmetic(current, amount, app.target, app.rules.sign_of(app.mutation.op))
          end
        end

        def apply_multiply(app)
          apply_numeric(app) { |current, amount| app.rules.multiply(current, amount, app.target) }
        end

        # Reads the amount against the element as it was, lets the block combine it with the
        # current value, and stores the result back as the attribute's own type.
        def apply_numeric(app)
          attribute = app.attribute
          amount    = app.source_value
          current   = app.current
          amount    = Value.for_attribute(app.aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = yield(current, amount)
          app.element[app.target] = rewrap_arithmetic_result(app.aggregate, attribute, current, result)
        end

        def apply_clamp(app)
          app.element[app.target] = app.rules.clamp(app.current, app.mutation.source, app.target)
        end

        def apply_nothing(_app)
          nil
        end

        # The element an append adds: a value object, or a nested entity with its identity checked.
        def appended_element(aggregate, entity, mutation, current, fields)
          element_type = entity.attribute(mutation.target)&.type
          value_object = aggregate.value_object(element_type)
          unwrap_scalar_fields(value_object, fields)
          return Value.build(value_object, fields, aggregate) if value_object

          nested_element(aggregate, entity, element_type, current, fields)
        end

        def unwrap_scalar_fields(value_object, fields)
          value_object&.attributes&.each do |attribute|
            fields[attribute.name] = Value.scalar(fields[attribute.name]) if fields[attribute.name].is_a?(Value)
          end
        end

        # `entity.entities`, not `aggregate.entities` — a nested piece is a child of
        # the owning entity, not of the root aggregate.
        def nested_element(aggregate, entity, element_type, current, fields)
          nested_entity = entity.entities.find { |piece| piece.hecks_name == element_type.to_s }
          return fields unless nested_entity

          check_entity_collision(entity, nested_entity, current, fields)
          fill_declared_defaults(aggregate, nested_entity, fields)
        end
      end
    end
  end
end
