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
          raw_field_names.each do |name|
            fields << { name: name, attribute: nil, sql_type: "TEXT" } unless fields.any? { |f| f[:name] == name }
          end
          fields
        end

        # The lifecycle field and the `projects` fields. `projects` fields are written straight
        # into `Instance#state`, so they need a column or `project` drops them. They carry no
        # attribute and are stored as raw scalars, like the lifecycle field.
        def raw_field_names
          lifecycle = @aggregate.lifecycle
          (lifecycle ? [lifecycle.field] : []) + @aggregate.projected_fields.map(&:name)
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

          # A reference holds a head's id, which is text and would fail JSON.parse.
          raw
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
