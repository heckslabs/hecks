module Hecks
  module Projector
    module CliProjector
      # The option specs of a command or query: one per leaf field of each declared attribute,
      # typed by the declared field type and never by guessing at the string.
      module Arguments
        module_function

        # The options that name the record a command acts on, before its own arguments.
        # `nil` (a creating command) takes none: there is no record yet.
        # Ports always pass `:aggregate`, since a port is declared on an aggregate.
        #
        # @param receiver [Symbol, nil] `:entity`, `:aggregate` or `nil`
        # @param aggregate [Bluebook::Aggregate] the aggregate holding the record
        # @param entity [Bluebook::Entity, nil] the entity acted on, for an `:entity` receiver
        # @return [Array<Hash{Symbol => Object}>] the receiver option specs
        def receiver_options(receiver, aggregate, entity)
          case receiver
          when :entity then entity_receiver(aggregate, entity)
          when :aggregate then aggregate_receiver(aggregate)
          else []
          end
        end

        # The two ids that address an entity inside its aggregate.
        def entity_receiver(aggregate, entity)
          [
            { path: "to.aggregate", type: "String", required: true,
              note: "id of the #{aggregate.hecks_name} holding the #{entity.hecks_name}" },
            { path: "to.entity", type: "String", required: true,
              note: "id of the #{entity.hecks_name} to act on" }
          ]
        end

        # The id that addresses an aggregate.
        def aggregate_receiver(aggregate)
          [{ path: "to", type: "String", required: true,
             note: "id of the #{aggregate.hecks_name} to act on" }]
        end

        # Flattens an attribute into one option per leaf field. A value object becomes
        # dotted options (`--commit.value`), recursing into nested value objects so
        # `{ cents: 1500 }` is never sent as the string "1500".
        #
        # @param attribute [Bluebook::Attribute] the field being projected
        # @param holder [Bluebook::Aggregate, Bluebook::Entity, Class] what declares `attribute`
        # @param aggregate [Bluebook::Aggregate] the top-level aggregate, kept across recursion
        # @param prefix [String, nil] the dotted path built so far
        # @param optional [Boolean, nil] whether an enclosing field already makes this one optional
        # @return [Array<Hash{Symbol => Object}>] one option spec per leaf field
        def options_for(attribute, holder, aggregate, prefix = nil, optional = nil)
          path = [prefix, attribute.name].compact.join(".")
          optional ||= attribute.optional?
          return [reference_option(attribute)] if attribute.reference?

          value_object = value_object_for(attribute, holder, aggregate)
          return with_declared_default([scalar_option(path, attribute, optional)], attribute) unless value_object

          fields = with_declared_default(value_object_options(value_object, aggregate, path, optional), attribute)
          attribute.list? ? fields.map { |option| listed(option) } : fields
        end

        # The list flag rides on each leaf: without it a repeated flag overwrote the
        # leaf silently, and CliDoor only ever sees a path and a spec.
        def value_object_options(value_object, aggregate, path, optional)
          value_object.attributes.flat_map do |field|
            if value_object_for(field, value_object, aggregate)
              options_for(field, value_object, aggregate, path, optional)
            else
              scalar_option("#{path}.#{field.name}", field, optional || field.optional?,
                            enum: closed_members(value_object, field))
            end
          end
        end

        # `option` marked as one element of a repeatable list.
        def listed(option)
          option.merge(list: true, note: [option[:note], "repeatable"].compact.join("; "))
        end

        # Shows the default the attribute itself declares (`attribute :runs, Count, default: 30`) on
        # the leaf it fills: the matching field for a hash default, the lone field for a bare one.
        # An argument with a default is never required, since the runtime fills it when omitted.
        #
        # @param options [Array<Hash{Symbol => Object}>] the attribute's leaf option specs
        # @param attribute [Object] the attribute, which may declare a default
        # @return [Array<Hash{Symbol => Object}>] `options`, with the default shown where it lands
        def with_declared_default(options, attribute)
          declared = attribute.default if attribute.respond_to?(:default)
          return options if declared.nil?

          options.map { |option| default_shown(option, declared, options.one?) }
        end

        # `option` with `declared` shown as its default when `declared` has a value for it.
        def default_shown(option, declared, lone)
          leaf = option[:path].split(".").last
          value = declared.is_a?(Hash) ? declared.fetch(leaf.to_sym) { declared[leaf] } : (declared if lone)
          value.nil? ? option : option.merge(default: value, required: false)
        end

        # The option for a reference attribute: the id of the record it points at.
        def reference_option(attribute)
          { path: attribute.name.to_s, type: "String", required: !attribute.optional?,
            note: "id of a #{attribute.type.target_name}" }
        end

        # A `list_of` scalar carries `list: true, words: true`: the launcher reads a comma-separated
        # value or a repeated name as the list's elements, since the runtime refuses a lone scalar.
        def scalar_option(path, field, optional, enum: [])
          option = { path: path, type: field.type.to_s, required: !optional }
          option.merge!(list: true, words: true, note: "list: comma-separated or repeated") if field.list?
          option[:enum] = enum unless enum.empty?
          option.merge!(declared_traits(field))
        end

        # The pattern and default a field itself declares, for the keys it declares.
        def declared_traits(field)
          traits = {}
          traits[:pattern] = field.pattern if field.respond_to?(:pattern) && field.pattern
          traits[:default] = field.default if field.respond_to?(:default) && !field.default.nil?
          traits
        end

        # The values a `one_of` value object's field is closed to, or `[]` for an open one.
        def closed_members(value_object, field)
          return [] unless value_object.closed_set?

          value_object.members.filter_map { |member| member[field.name] }.uniq
        end

        # The `Bluebook::ValueObject` subclass an attribute's type names, searching
        # `holder` then `aggregate`, or `nil` for a plain scalar.
        def value_object_for(attribute, holder, aggregate)
          [holder, aggregate].compact.each do |scope|
            next unless scope.respond_to?(:value_objects)

            found = scope.value_objects.find { |v| v.hecks_name == attribute.type.to_s }
            return found if found
          end
          nil
        end
      end
    end
  end
end
