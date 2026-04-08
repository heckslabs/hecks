module Hecks
  class DslSerializer
    # Hecks::DslSerializer::TypeHelpers
    #
    # Attribute type formatting and reference serialization for the DSL output.
    #
    #   # Mixed into DslSerializer
    #   dsl_type(attr)        # => "String" or "list_of(\"Topping\")"
    #   serialize_attributes(attrs, "    ")
    #   serialize_references(refs, "    ")
    #
    module TypeHelpers
      def serialize_attributes(attrs, indent)
        attrs.map { |a| "#{indent}attribute :#{a.name}, #{dsl_type(a)}" }
      end

      def serialize_references(refs, indent)
        (refs || []).map { |ref| format_reference(ref, indent) }
      end

      def dsl_type(attr)
        attr.list? ? "list_of(\"#{attr.type}\")" : attr.type.to_s
      end

      private

      def format_reference(ref, indent)
        role_opt = default_role?(ref) ? "" : ", role: \"#{ref.name}\""
        qualified = ref.domain ? "#{ref.domain}::#{ref.type}" : ref.type
        "#{indent}reference_to \"#{qualified}\"#{role_opt}"
      end

      def default_role?(ref)
        underscored = ref.type.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                              .downcase
        ref.name.to_s == underscored
      end
    end
  end
end
