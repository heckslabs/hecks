require_relative "../../../runtime/value"

module Hecksagain
  module Adapters
    class Postgres
      # How a state crosses the column boundary: which fields persist, and
      # how each one encodes into (and decodes out of) its column. Same
      # SHAPE as Sqlite::Codec (one column per attribute, JSON for
      # nested/list) — not its mechanics. Sqlite's own columns carry no
      # type affinity worth trusting on the way back out (SQLite gives it
      # back typed anyway via the driver), but `pg` hands every column
      # back as TEXT unless a type map says otherwise, so a real `bigint`/
      # `double precision` column needs its OWN coercion on decode that
      # Sqlite never had to write.
      module Codec
        private

        def persisted_fields
          fields = @aggregate.attributes.reject { |attribute| attribute.name == :id }.map do |attribute|
            { name: attribute.name, attribute: attribute, sql_type: sql_type(attribute) }
          end
          lifecycle = @aggregate.lifecycle
          if lifecycle && !fields.any? { |field| field[:name] == lifecycle.field }
            fields << { name: lifecycle.field, attribute: nil, sql_type: "text" }
          end
          fields
        end

        def encode(attr, value)
          # NEVER SET IS NOT EMPTY — same reasoning as Sqlite::Codec's own
          # comment: a list attribute nothing has ever appended to has to
          # stay NULL to answer the same as Memory does, not become `[]`
          # invented by this adapter's own storage.
          return (value.nil? ? nil : JSON.generate(value)) if attr.list?
          return JSON.generate(value) if value.is_a?(Hash) || value.is_a?(Runtime::Value)

          value
        end

        def encode_field(field, value)
          return value unless field[:attribute]

          encode(field[:attribute], value)
        end

        def decode(row)
          persisted_fields.each_with_object({}) do |field, state|
            attr = field[:attribute]
            unless attr
              state[field[:name]] = row[field[:name].to_s]
              next
            end
            raw = row[attr.name.to_s]
            state[attr.name] =
              if attr.list? || value_object?(attr)
                raw ? JSON.parse(raw, symbolize_names: true) : nil
              else
                coerce_scalar(attr, raw)
              end
          end
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
