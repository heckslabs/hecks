# = Hecks::MongoAdapterGenerator::SerializationLines
#
# Mixin for MongoAdapterGenerator that builds the serialize/deserialize
# method source strings for generated repository classes. Handles scalar
# attributes, single embedded value objects, and list value objects.
#
#   include SerializationLines
#   serialize_lines(6)    # => Array of Ruby source lines
#   deserialize_lines(6)  # => Array of Ruby source lines
#
module Hecks
  class MongoAdapterGenerator
    module SerializationLines
      private

      def scalar_attributes
        @aggregate.attributes.reject(&:list?)
      end

      def list_value_objects
        @aggregate.value_objects.select do |vo|
          @aggregate.attributes.any? { |a| a.list? && a.type.to_s == vo.name }
        end
      end

      def single_vo_attributes
        @aggregate.value_objects.reject do |vo|
          @aggregate.attributes.any? { |a| a.list? && a.type.to_s == vo.name }
        end.select do |vo|
          @aggregate.attributes.any? { |a| !a.list? && a.type.to_s == vo.name }
        end
      end

      def vo_attribute?(attr)
        vo_names = (@aggregate.value_objects || []).map(&:name)
        vo_names.include?(attr.type.to_s)
      end

      def serialize_lines(indent)
        pad = " " * indent
        refs = @aggregate.references || []

        scalar_fields = scalar_attributes.reject { |a| vo_attribute?(a) }.map do |a|
          "\"#{a.name}\" => obj.#{a.name}"
        end
        ref_fields = refs.map do |r|
          "\"#{r.name}_id\" => obj.respond_to?(:#{r.name}_id) ? obj.#{r.name}_id : nil"
        end
        single_vo_fields = single_vo_attributes.map do |vo|
          attr = @aggregate.attributes.find { |a| !a.list? && a.type.to_s == vo.name }
          next unless attr
          vo_hash = vo.attributes.map { |va| "\"#{va.name}\" => obj.#{attr.name}&.#{va.name}" }.join(", ")
          "\"#{attr.name}\" => obj.#{attr.name} ? { #{vo_hash} } : nil"
        end.compact
        list_vo_fields = list_value_objects.map do |vo|
          attr = @aggregate.attributes.find { |a| a.list? && a.type.to_s == vo.name }
          next unless attr
          vo_hash = vo.attributes.map { |va| "\"#{va.name}\" => item.#{va.name}" }.join(", ")
          "\"#{attr.name}\" => (obj.#{attr.name} || []).map { |item| { #{vo_hash} } }"
        end.compact

        all_fields = scalar_fields + ref_fields + single_vo_fields + list_vo_fields
        [
          "#{pad}def serialize(obj)",
          "#{pad}  {",
          "#{pad}    \"_id\" => obj.id,",
          *all_fields.map { |f| "#{pad}    #{f}," },
          "#{pad}    \"created_at\" => obj.respond_to?(:created_at) ? obj.created_at&.to_s : nil,",
          "#{pad}    \"updated_at\" => obj.respond_to?(:updated_at) ? obj.updated_at&.to_s : nil",
          "#{pad}  }",
          "#{pad}end"
        ]
      end

      def deserialize_lines(indent)
        pad = " " * indent
        scalar_params = scalar_attributes.reject { |a| vo_attribute?(a) }.map do |a|
          "#{a.name}: doc[\"#{a.name}\"]"
        end
        single_vo_params = single_vo_attributes.map do |vo|
          attr = @aggregate.attributes.find { |a| !a.list? && a.type.to_s == vo.name }
          next unless attr
          vo_attr_args = vo.attributes.map { |va| "#{va.name}: h[\"#{va.name}\"]" }.join(", ")
          vo_class = "#{@safe_name}::#{vo.name}"
          "#{attr.name}: (h = doc[\"#{attr.name}\"]) ? #{vo_class}.new(#{vo_attr_args}) : nil"
        end.compact
        list_vo_params = list_value_objects.map do |vo|
          attr = @aggregate.attributes.find { |a| a.list? && a.type.to_s == vo.name }
          next unless attr
          vo_attr_args = vo.attributes.map { |va| "#{va.name}: h[\"#{va.name}\"]" }.join(", ")
          vo_class = "#{@safe_name}::#{vo.name}"
          "#{attr.name}: (doc[\"#{attr.name}\"] || []).map { |h| #{vo_class}.new(#{vo_attr_args}) }"
        end.compact

        all_params = scalar_params + single_vo_params + list_vo_params
        [
          "#{pad}def deserialize(doc)",
          "#{pad}  klass = #{@domain_module}.const_get(\"#{@safe_name}\")",
          "#{pad}  obj = klass.new(#{all_params.join(", ")})",
          "#{pad}  obj.instance_variable_set(:@id, doc[\"_id\"]) if doc[\"_id\"]",
          "#{pad}  obj",
          "#{pad}end"
        ]
      end
    end
  end
end
