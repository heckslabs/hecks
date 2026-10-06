module Hecks
  module Projector
    module CliProjector
      # The options of a command or query: one per leaf field, typed from the declared field
      # type and carrying its enum, pattern, default and list flag.
      module OptionSpecs
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

          fields = with_declared_default(leaf_options(value_object, aggregate, path, optional), attribute)
          attribute.list? ? fields.map { |option| repeatable(option) } : fields
        end

        # One option per field of a value object, recursing into a field that is itself one.
        #
        # The list flag rides on each leaf: without it a repeated flag overwrote the
        # leaf silently, and CliDoor only ever sees a path and a spec.
        def leaf_options(value_object, aggregate, path, optional)
          value_object.attributes.flat_map do |field|
            nested = value_object_for(field, value_object, aggregate)
            next options_for(field, value_object, aggregate, path, optional) if nested

            scalar_option("#{path}.#{field.name}", field, optional || field.optional?,
                          enum: closed_members(value_object, field))
          end
        end

        # The option marked as one that may be given more than once.
        def repeatable(option)
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

          options.map do |option|
            value = leaf_default(declared, option[:path].split(".").last, options)
            value.nil? ? option : option.merge(default: value, required: false)
          end
        end

        # The part of a declared default that fills the leaf named `leaf`.
        def leaf_default(declared, leaf, options)
          return declared.fetch(leaf.to_sym) { declared[leaf] } if declared.is_a?(Hash)

          declared if options.one?
        end

        # The option of an attribute that references another record, which is given by its id.
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
          option.merge!(declared_rules(field))
        end

        # The pattern and default a field declares, when it declares them.
        def declared_rules(field)
          rules = {}
          rules[:pattern] = field.pattern if field.respond_to?(:pattern) && field.pattern
          rules[:default] = field.default if field.respond_to?(:default) && !field.default.nil?
          rules
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
