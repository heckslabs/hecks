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
          lifecycle = @aggregate.lifecycle
          fields << { name: lifecycle.field, attribute: nil, sql_type: "text" } if lifecycle && fields.none? do |field|
            field[:name] == lifecycle.field
          end
          # `projects` fields are local columns too (ADR 0025).
          @aggregate.projected_fields.each do |field|
            next if fields.any? { |f| f[:name] == field.name }

            fields << { name: field.name, attribute: nil, sql_type: "text" }
          end
          fields
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
          state = persisted_fields.each_with_object({}) do |field, raw_state|
            attr = field[:attribute]
            unless attr
              value = row[field[:name].to_s]
              next if value.nil? && projected_only?(field)

              raw_state[field[:name]] = value
              next
            end
            raw = row[attr.name.to_s]
            raw_state[attr.name] =
              if attr.list? || value_object?(attr)
                raw ? JSON.parse(raw) : nil
              else
                coerce_scalar(attr, raw)
              end
          end
          Ports::Persistence::StateCodec.decode(@aggregate, state)
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
