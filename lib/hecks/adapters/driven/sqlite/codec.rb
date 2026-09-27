require_relative "../../../runtime/value"

module Hecks
  module Adapters
    class Sqlite
      # How a state crosses the column boundary: which fields persist,
      # and how each one encodes into (and decodes out of) its column.
      module Codec
        private

        def persisted_fields
          fields = @aggregate.attributes.reject { |attribute| attribute.name == :id }.map do |attribute|
            { name: attribute.name, attribute: attribute, sql_type: sql_type(attribute) }
          end
          lifecycle = @aggregate.lifecycle
          fields << { name: lifecycle.field, attribute: nil, sql_type: "TEXT" } if lifecycle && fields.none? do |field|
            field[:name] == lifecycle.field
          end
          # `projects` fields are written straight into `Instance#state`, so they need a column
          # or `project` drops them. They carry no attribute and are stored as raw scalars,
          # like the lifecycle field.
          @aggregate.projected_fields.each do |field|
            next if fields.any? { |f| f[:name] == field.name }

            fields << { name: field.name, attribute: nil, sql_type: "TEXT" }
          end
          fields
        end

        def encode(attr, value)
          # A list nothing has appended to stays NULL, as under Memory; forcing `[]` would
          # invent data no dispatch wrote.
          return (value.nil? ? nil : state_json(value)) if attr.list?
          return state_json(value) if value.is_a?(Hash) || value.is_a?(Runtime::Value)

          value
        end

        def encode_field(field, value)
          return value unless field[:attribute]

          encode(field[:attribute], value)
        end

        def state_json(value) = JSON.generate(Ports::Persistence::StateCodec.encode(@aggregate, value))

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
                # A reference holds a head's id, which is text and would fail JSON.parse.
                raw
              end
          end
          Ports::Persistence::StateCodec.decode(@aggregate, state)
        end

        # A NULL `projects` column means never seeded, so it reads back absent as under Heki and
        # PostgresEra; nothing stores a nil projected value. The lifecycle field keeps its NULL.
        def projected_only?(field)
          @aggregate.lifecycle&.field&.to_sym != field[:name].to_sym &&
            @aggregate.projected_fields.any? { |projected| projected.name.to_sym == field[:name].to_sym }
        end
      end
    end
  end
end
