module Hecks
  module Projector
    module DocsProjector
      # The attribute table of an aggregate or entity: each field's name, shape and rules.
      module Attributes
        module_function

        # The table of `holder`'s own attributes, or `nil` when it has none besides references.
        def table_for(holder)
          attributes = holder.attributes.reject(&:reference?)
          return nil if attributes.empty?

          rows = attributes.map do |attribute|
            ["`#{attribute.name}`", shape_of(attribute, holder), rules_of(attribute, holder)]
          end
          DocsProjector.table(%w[attribute shape rules], rows)
        end

        # A value object's fields, not its name: callers need to know what shape to send.
        def shape_of(attribute, holder)
          value_object = value_object_for(attribute, holder)
          inner =
            if value_object
              "{ #{value_object.attributes.map { |f| "#{f.name}: #{f.type}" }.join(", ")} }"
            else
              attribute.type.to_s
            end
          shape = attribute.list? ? "list of #{inner}" : inner
          attribute.optional? ? "#{shape} *(optional)*" : shape
        end

        # The rules an attribute carries: closed set, field patterns and defaults, invariants,
        # and its own default, joined for one table cell.
        def rules_of(attribute, holder)
          value_object = value_object_for(attribute, holder)
          rules = closed_rules(value_object) + field_rules(value_object) +
                  Array(value_object&.invariants).map(&:description)
          rules << "defaults to `#{attribute.default.inspect}`" unless attribute.default.nil?
          rules.empty? ? "" : rules.join("; ")
        end

        # The "one of" rule of a closed value object, or no rule for an open one.
        def closed_rules(value_object)
          members = closed_members(value_object)
          members.any? ? ["one of #{members.map { |m| "`#{m}`" }.join(", ")}"] : []
        end

        # The pattern and default each field of a value object declares.
        def field_rules(value_object)
          Array(value_object&.attributes).flat_map do |field|
            rules = []
            rules << "`#{field.name}` matches `#{field.pattern}`" if field.pattern
            rules << "`#{field.name}` defaults to `#{field.default.inspect}`" unless field.default.nil?
            rules
          end
        end

        def closed_members(value_object)
          return [] unless value_object&.closed_set?

          value_object.members.flat_map(&:values).uniq
        end

        # An entity holds no value objects; its types are declared on the owning aggregate.
        def value_object_for(attribute, holder)
          scopes = [holder, holder.respond_to?(:hecks_owner) ? holder.hecks_owner : nil].compact
          scopes.each do |scope|
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
