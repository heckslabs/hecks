require_relative "../../../runtime/value"

module Hecks
  module Adapters
    class Postgres
      # Encodes and decodes a state to and from its columns, coercing `pg`'s text back to
      # numbers.
      module Codec
        private

        def persisted_fields
          fields = @aggregate.attributes.reject { |attribute| attribute.name == :id }.map do |attribute|
            { name: attribute.name, attribute: attribute, sql_type: sql_type(attribute) }
          end
          raw_field_names.each do |name|
            fields << { name: name, attribute: nil, sql_type: "text" } unless fields.any? { |f| f[:name] == name }
          end
          fields
        end

        # The lifecycle field and the `projects` fields, which are local columns too (ADR 0025).
        def raw_field_names
          lifecycle = @aggregate.lifecycle
          (lifecycle ? [lifecycle.field] : []) + @aggregate.projected_fields.map(&:name)
        end

        def encode(attr, value)
          # A never-set list stays NULL rather than becoming `[]`, matching Memory.
          return (value.nil? ? nil : state_json(value)) if attr.list?
          return state_json(value) if value.is_a?(Hash) || value.is_a?(Runtime::Value)

          value
        end

        def encode_field(field, value)
          return value unless field[:attribute]

          encode(field[:attribute], value)
        end

        def state_json(value) = JSON.generate(Ports::Persistence::StateCodec.encode(@aggregate, value))

        # A NULL projected-only column reads back absent.
        def decode(row)
          state = persisted_fields.each_with_object({}) { |field, raw_state| decode_field(row, field, raw_state) }
          Ports::Persistence::StateCodec.decode(@aggregate, state)
        end

        def decode_field(row, field, raw_state)
          attr = field[:attribute]
          return decode_raw_field(row, field, raw_state) unless attr

          raw_state[attr.name] = decode_stored(attr, row[attr.name.to_s])
        end

        def decode_raw_field(row, field, raw_state)
          value = row[field[:name].to_s]
          return if value.nil? && projected_only?(field)

          raw_state[field[:name]] = value
        end

        def decode_stored(attr, raw)
          return raw ? JSON.parse(raw) : nil if attr.list? || value_object?(attr)

          coerce_scalar(attr, raw)
        end

        def projected_only?(field)
          @aggregate.lifecycle&.field&.to_sym != field[:name].to_sym &&
            @aggregate.projected_fields.any? { |projected| projected.name.to_sym == field[:name].to_sym }
        end

        # `pg` returns every column as a String, so numeric columns are coerced back.
        def coerce_scalar(attr, raw)
          return nil if raw.nil?

          case attr.type
          when "Integer" then raw.to_i
          when "Float"   then raw.to_f
          else raw
          end
        end
      end
    end
  end
end
