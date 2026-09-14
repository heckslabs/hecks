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
          return (value.nil? ? nil : state_json(value)) if attr.list?
          return state_json(value) if value.is_a?(Hash) || value.is_a?(Runtime::Value)

          value
        end

        def encode_field(field, value)
          return value unless field[:attribute]

          encode(field[:attribute], value)
        end

        # Every JSON column's text goes through the state codec's `encode`
        # (PR A3) — string keys at every depth, Values materialized.
        def state_json(value) = JSON.generate(Ports::Persistence::StateCodec.encode(@aggregate, value))

        # The row's columns reassembled into the stored state, then decoded
        # ONCE through the state codec (PR A3) — the same deep, IR-driven
        # key spelling every other adapter's read now produces, instead of
        # this codec's own `symbolize_names:` walk.
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
                # A REFERENCE lands here now, with the ordinary scalars. It holds
                # the id of a head, which is text — `JSON.parse("acct-1")` raises,
                # so reading it as JSON was only ever survivable while the column
                # held an object.
                raw
              end
          end
          Ports::Persistence::StateCodec.decode(@aggregate, state)
        end

        # A NULL `projects` COLUMN IS A FIELD NEVER SEEDED, NOT A STORED
        # NIL — so it reads back ABSENT, the way Heki/PostgresEra (one blob
        # holding only what was written) already answer it. A column holds
        # every persisted field whether or not the record ever had one, so
        # NULL is the only spelling "never set" has here; and nothing ever
        # stores a nil projected value to confuse it with —
        # `CommandInterpreter#seed_projected_fields` and
        # `RebuildSweep#refresh` both skip a nil remote value. Absent is also
        # what `RebuildSweep#refresh`'s `record.key?` and
        # `Registry#projection_current?`'s row comparison expect. The
        # lifecycle field (the other `attribute: nil` column) keeps its NULL.
        def projected_only?(field)
          @aggregate.lifecycle&.field&.to_sym != field[:name].to_sym &&
            @aggregate.projected_fields.any? { |projected| projected.name.to_sym == field[:name].to_sym }
        end
      end
    end
  end
end
