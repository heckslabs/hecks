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
          # `projects` FIELDS (S12, ADR 0025) ARE A LOCAL COLUMN TOO —
          # `CommandInterpreter#seed_projected_fields`/`RebuildSweep`
          # both write one straight into `Instance#state` the same as
          # any other field, so a column has to exist to hold it or
          # `save`'s own `columns =`/`values =` build (this file, not
          # here) silently drops it on every write. No `attribute` of
          # their own to carry (`ProjectedField` is a bare name/
          # reference/remote_field triple, not a typed attribute) —
          # treated as a raw scalar, same as the lifecycle field just
          # above: every real corpus use projects a status/lifecycle
          # string, and `encode_field`/`decode` both already pass a
          # `attribute: nil` field through untouched, not JSON-encoded.
          @aggregate.projected_fields.each do |field|
            next if fields.any? { |f| f[:name] == field.name }

            fields << { name: field.name, attribute: nil, sql_type: "TEXT" }
          end
          fields
        end

        def encode(attr, value)
          # NEVER SET IS NOT EMPTY. `then_set ... append:` starts a list at `[]`
          # the moment the first element lands, but a list attribute nothing has
          # ever appended to — the shape every OTHER aggregate in the corpus
          # happened not to carry, until one declared a list-typed head
          # attribute that no creating command populates by default — has to
          # stay NULL to answer the same as Memory does. Forcing it to `[]`
          # here is how a persistence topology invented data no dispatch wrote.
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
                # A REFERENCE lands here now, with the ordinary scalars. It holds
                # the id of a head, which is text — `JSON.parse("acct-1")` raises,
                # so reading it as JSON was only ever survivable while the column
                # held an object.
                raw
              end
          end
        end
      end
    end
  end
end
