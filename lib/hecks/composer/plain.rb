module Hecks
  module Composer
    # Reduces what a booted domain hands back (records, events, value objects) to plain Hashes,
    # Arrays and scalars, so the page can show it as JSON.
    module Plain
      module_function

      # @param item [Object] a value object, record, event, or a Hash or Array of them
      # @return [Object] the same, with every value object replaced by its bare value: one of a
      #   single field is that field's value, and one of several is a Hash of them
      def call(item)
        case item
        when Runtime::Value then bare(item)
        when Runtime::Instance, Runtime::Event then call(item.to_h)
        when Hash then item.transform_values { |inner| call(inner) }
        when Array then item.map { |inner| call(inner) }
        else item
        end
      end

      # @api private
      def bare(value)
        fields = call(value.to_h)
        fields.size == 1 ? fields.values.first : fields
      end
    end
  end
end
