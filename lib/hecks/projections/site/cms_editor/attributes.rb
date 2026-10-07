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
        # name is entered as text.
        #
        # An attribute whose value object has the shape of a structured document, a `blocks`
        # list of a value object that has `kind` and `spans`, carries `widget: "body"` and is
        # edited with the rich-text widget. The shape decides it, never a name.
        class Attributes
          # The parts a value object needs for its list of blocks to be a document body's blocks.
          BLOCK_PARTS = %w[kind spans].freeze

          # The kind a primitive's name enters as; any other name is text.
          KINDS = { "Integer" => "integer", "Float" => "number", "Boolean" => "boolean", "TrueClass" => "boolean",
                    "FalseClass" => "boolean" }.freeze

          # @param objects [Array<Bluebook::ValueObject>] the aggregate's value objects
          def initialize(objects)
            @by_name = objects.to_h { |object| [object.hecks_name, object] }
            @objects = @by_name.keys
          end

          # @param attribute [Bluebook::Attribute] a declared attribute
          # @return [Hash{String => Object}] the attribute as the editor reads it
          def of(attribute)
            type = attribute.type
            return reference(attribute, type.target_name) if type.is_a?(Bluebook::Reference)

            entry = base(attribute, type.to_s, kind(type.to_s))
            body?(attribute) ? entry.merge("widget" => "body") : entry
          end

          private

          # A single (not listed) attribute whose value object holds a list of document blocks.
          def body?(attribute)
            return false if attribute.list?

            block = block_object(@by_name[attribute.type.to_s])
            !block.nil? && (BLOCK_PARTS - block.attributes.map { |part| part.name.to_s }).empty?
          end

          # @return [Bluebook::ValueObject, nil] the value object `object`'s `blocks` list holds
          def block_object(object)
            blocks = object&.attributes&.find { |part| part.name.to_s == "blocks" && part.list? }
            blocks && @by_name[blocks.type.to_s]
          end

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
