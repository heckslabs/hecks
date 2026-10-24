require_relative "../../../runtime/instance"

module Hecks
  module Adapters
    module Projection
      # Reads a projected row of any aggregate back into an instance, so one adapter can answer
      # every head of a read model and not only its own aggregate.
      #
      # The including adapter supplies `decode_column(aggregate, attribute, raw)`: how one
      # declared column's stored text reads back in its dialect.
      module RowDecoding
        private

        def projected_instance(aggregate, row)
          Runtime::Instance.new(aggregate: aggregate, id: row["id"], state: decode_for(aggregate, row))
        end

        def decode_for(aggregate, row)
          decode_fields(fields_for(aggregate), aggregate, row)
        end

        # Declared attributes plus the lifecycle field and any unlisted
        # `projects` fields, all read back raw (see `decode_fields`).
        def fields_for(aggregate)
          fields = aggregate.attributes.map { |attribute| [attribute.name, attribute] }
          # `projects` fields (ADR 0025) read back raw too, as the adapter's `persisted_fields` writes them.
          lifecycle = aggregate.lifecycle
          raw_names = (lifecycle ? [lifecycle.field] : []) + aggregate.projected_fields.map(&:name)
          raw_names.each { |raw| fields << [raw, nil] unless fields.any? { |name, _| name == raw } }
          fields
        end

        # Decoded through the state codec against the row's own aggregate, so a NULL
        # projected-only column reads back absent.
        def decode_fields(fields, aggregate, row)
          state = fields.each_with_object({}) do |(name, attribute), raw_state|
            raw = row[name.to_s]
            next if unset_projected?(aggregate, name, attribute, raw)

            raw_state[name] = decode_column(aggregate, attribute, raw)
          end
          Ports::Persistence::StateCodec.decode(aggregate, state)
        end

        # A NULL column with no attribute reads back absent, except the lifecycle field.
        def unset_projected?(aggregate, name, attribute, raw)
          attribute.nil? && raw.nil? && aggregate.lifecycle_field&.to_sym != name.to_sym
        end

        # Whether `attribute` is stored as JSON: a list, or a value object of `aggregate`.
        def json_column?(aggregate, attribute)
          attribute.list? || !aggregate.value_object(attribute.type).nil?
        end
      end
    end
  end
end
