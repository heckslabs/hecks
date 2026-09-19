require_relative "../../../runtime/value"

module Hecks
  module Adapters
    class Postgres
      # How a state crosses the column boundary: which fields persist, and
      # how each one encodes into (and decodes out of) its column. Same
      # shape as Sqlite::Codec (one column per attribute, JSON for
      # nested/list) — not its mechanics. Sqlite's own columns carry no
      # type affinity worth trusting on the way back out (SQLite gives it
      # back typed anyway via the driver), but `pg` hands every column
      # back as text unless a type map says otherwise, so a real `bigint`/
      # `double precision` column needs its own coercion on decode that
      # Sqlite never had to write.
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
          # `projects` fields (S12, ADR 0025) are a local column too — see
          # Sqlite::Codec#persisted_fields' own comment; identical reasoning,
          # `text` to match this file's own lowercase SQL type spelling.
          @aggregate.projected_fields.each do |field|
            next if fields.any? { |f| f[:name] == field.name }

            fields << { name: field.name, attribute: nil, sql_type: "text" }
          end
          fields
        end

        def encode(attr, value)
          # Never set is not empty — same reasoning as Sqlite::Codec's own
          # comment: a list attribute nothing has ever appended to has to
          # stay NULL to answer the same as Memory does, not become `[]`
          # invented by this adapter's own storage.
          return (value.nil? ? nil : state_json(value)) if attr.list?
          return state_json(value) if value.is_a?(Hash) || value.is_a?(Runtime::Value)

          value
        end

        def encode_field(field, value)
          return value unless field[:attribute]

          encode(field[:attribute], value)
        end

        # Every jsonb column's text goes through the state codec's `encode`
        # (PR A3) — see Sqlite::Codec#state_json.
        def state_json(value) = JSON.generate(Ports::Persistence::StateCodec.encode(@aggregate, value))

        # Columns reassembled, then decoded once through the state codec
        # (PR A3) — see Sqlite::Codec#decode, including why a NULL
        # projected-only column reads back absent.
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

        # `pg` returns every column as a Ruby String by default (no type
        # map installed) — a `bigint`/`double precision` column has to be
        # coerced back on the way out, unlike Sqlite3's own driver, which
        # already types a row by the column's declared affinity. Mirrors
        # SQL_TYPES' own mapping: whatever gets a real numeric column here
        # gets converted back here, everything else (String, references,
        # enums, ...) passes through as the text it already is.
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
