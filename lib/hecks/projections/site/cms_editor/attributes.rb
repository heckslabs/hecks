# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # One attribute as the editor reads it: its name, the type as the bluebook spells it, how a
        # value of it is entered (`kind`), and whether it is optional or a list.
        #
        # A type that names one of the aggregate's value objects is an `object`; a reference is a
        # `reference`; the primitives are `integer`, `number`, `boolean` and `text`, and any other
        # name is entered as text. A value object named `Body` carries `widget: "body"`, which the
        # editor shows read-only until its rich-text widget lands.
        class Attributes
          # The value objects whose attribute is edited with a widget, by type name.
          WIDGETS = { "Body" => "body" }.freeze

          # The kind a primitive's name enters as; any other name is text.
          KINDS = { "Integer" => "integer", "Float" => "number", "Boolean" => "boolean", "TrueClass" => "boolean",
                    "FalseClass" => "boolean" }.freeze

          # @param objects [Array<String>] the names of the aggregate's value objects
          def initialize(objects)
            @objects = objects
          end

          # @param attribute [Bluebook::Attribute] a declared attribute
          # @return [Hash{String => Object}] the attribute as the editor reads it
          def of(attribute)
            type = attribute.type
            return reference(attribute, type.target_name) if type.is_a?(Bluebook::Reference)

            entry = base(attribute, type.to_s, kind(type.to_s))
            widget = WIDGETS[type.to_s]
            widget ? entry.merge("widget" => widget) : entry
          end

          private

          def reference(attribute, target)
            base(attribute, target, "reference").merge("target" => target)
          end

          def base(attribute, type, kind)
            { "name" => attribute.name.to_s, "type" => type, "kind" => kind,
              "optional" => attribute.optional?, "list" => attribute.list? }
          end

          def kind(type)
            return "object" if @objects.include?(type)

            KINDS.fetch(type, "text")
          end
        end
      end
    end
  end
end
