require "json"
require_relative "../../runtime/value"

module Hecks
  module Ports
    module Persistence
      # One spelling of an aggregate's state across the store boundary
      # (Phase 2, Track A, PR A2). Every adapter used to decode its own way
      # (spec/ports/persistence_legacy_decode_spec.rb pins today's shapes):
      # Heki heads and every journal reader symbolize the top level only,
      # Sqlite/D1/Postgres/PostgresEra/Lambda heads symbolize deep, and
      # Memory never serializes at all (a shallow `state.dup`). This codec is
      # the single, IR-driven answer those adapters converge on. Since A3
      # every adapter writes through `encode` and reads through `decode`
      # (Memory through `copy`), and `CodecBoundary` — installed on every
      # adapter `RepositoryFactory.build` makes — refuses an `Instance`
      # built inside an adapter call from state `decoded?` rejects.
      #
      # - `encode` — canonical and JSON-ready: string keys at every depth,
      #   `Runtime::Value`s materialized, only JSON scalars at the leaves.
      #   Needs no IR (JSON has one spelling), but takes it for symmetry.
      # - `decode` — walks the aggregate's IR: attributes, value objects
      #   (their fields, recursively), `list_of` value objects and entities
      #   (entity fields, nested entities, the entity's own lifecycle),
      #   references, the lifecycle field, and projected fields. A declared
      #   key becomes a symbol at every depth, whichever spelling arrived.
      # - `copy` — `decode(encode(state))`: what a durable adapter would hand
      #   back, for Memory, with no JSON text in between.
      #
      # **What decode never does**:
      #
      # It never invents a key. A declared field absent from the stored
      # state stays absent — not a present nil — because the runtime reads
      # absence as "this record predates the field": `Instance.
      # hydrate_with_defaults` fills a declared `default:` only when the key
      # is missing (spec/runtime/hydrate_defaults_spec.rb), Era translation
      # backfills only `unless state.key?` (era/lineage.rb#translate), and a
      # required declared-but-absent field reads as a named refusal rather
      # than nil (spec/runtime/attribute_absence_spec.rb). A present nil
      # would silently suppress all three. For the same reason it never
      # drops a key, nil or not: a stored nil stays a stored nil.
      #
      # It never touches an undeclared key's value — a retired field, or a
      # member a value object no longer declares, is exactly what an Era
      # translation (rename/move/drop) still has to read. Its key keeps its
      # spelling below the top level; at the top level every key is a
      # symbol, declared or not, because every adapter has always
      # symbolized the top level and `Lineage#translate` reads retired
      # top-level names as symbols.
      #
      # When a hash carries both spellings of one declared key, the symbol
      # spelling wins: it can only have been written by Ruby after the
      # string one was read.
      module StateCodec
        JSON_SCALARS = [String, Integer, Float, TrueClass, FalseClass, NilClass].freeze

        module_function

        def encode(_aggregate, state) = encode_value(state)

        def decode(aggregate, raw)
          return raw unless raw.is_a?(Hash)

          fields = declared_top_level(aggregate)
          decode_hash(aggregate, fields, raw, symbolize_undeclared: true)
        end

        def copy(aggregate, state) = decode(aggregate, encode(aggregate, state))

        # The field walk Sqlite::Codec#persisted_fields does for columns,
        # as name => Attribute (nil for the lifecycle field and projected
        # fields: bare scalars with no attribute of their own). The same
        # three sources, the same precedence — an attribute that happens to
        # share the lifecycle's or a projected field's name keeps its type.
        # An entity (no `projected_fields` of its own) gets its entity
        # field set — `decoded?` is asked about any `Instance`, and an
        # entity is "structurally interchangeable with an aggregate".
        def declared_top_level(aggregate)
          fields = entity_fields(aggregate)
          return fields unless aggregate.respond_to?(:projected_fields)

          aggregate.projected_fields.each { |field| fields[field.name.to_sym] = nil unless fields.key?(field.name.to_sym) }
          fields
        end

        # Whether `decode` would hand `state` back unchanged — every
        # top-level key a Symbol, every declared key below it a Symbol, no
        # hash carrying both spellings of a declared key. Allocates
        # nothing; `CodecBoundary` asks it of every `Instance` an adapter
        # builds. A `Runtime::Value` (hydrated state, a save's own entry)
        # already is the declared shape, so it answers true.
        def decoded?(aggregate, state)
          return true unless state.is_a?(Hash)

          hash_decoded?(aggregate, declared_top_level(aggregate), state, top: true)
        end

        # ── encode ──────────────────────────────────────────────────────

        def encode_value(value)
          case value
          when Runtime::Value then encode_value(value.to_h)
          when Hash then value.each_with_object({}) { |(key, inner), out| out[key.to_s] = encode_value(inner) }
          when Array then value.map { |inner| encode_value(inner) }
          when *JSON_SCALARS then value
          # A Symbol, a Time, anything else: exactly what `JSON.generate`
          # then `JSON.parse` would make of it, so Memory's copy and a
          # durable adapter's row agree on the leaf too.
          else JSON.parse(JSON.generate([value])).first
          end
        end

        # ── decode ──────────────────────────────────────────────────────

        # `fields` is name => Attribute-or-nil for this level. Key order is
        # kept; a string key is skipped when the same hash also holds its
        # symbol spelling, so the symbol wins wherever either one sits.
        def decode_hash(aggregate, fields, raw, symbolize_undeclared: false)
          raw.each_with_object({}) do |(key, value), out|
            name = key.to_s.to_sym
            next if key.is_a?(String) && raw.key?(name)

            if fields.key?(name)
              out[name] = decode_field(aggregate, fields[name], value)
            else
              out[symbolize_undeclared ? name : key] = value
            end
          end
        end

        # One declared field's value, by the four shapes `Value::Coercion`
        # names (scalar / list / optional / composite). nil, a reference (a
        # bare id or a list of them), and a scalar pass through untouched; a
        # value object or entity recurses only when the stored value really
        # is the Hash/Array its declaration says — anything else (a legacy
        # bare scalar for a one-field value object) is left for hydration.
        def decode_field(aggregate, attribute, value)
          return value if attribute.nil? || value.nil? || attribute.reference?

          if attribute.list?
            return value unless value.is_a?(Array)

            value.map { |element| decode_composite(aggregate, attribute.type.to_s, element) }
          else
            decode_composite(aggregate, attribute.type.to_s, value)
          end
        end

        def decode_composite(aggregate, type, value)
          return value unless value.is_a?(Hash)

          entity = Runtime::Value.find_entity(aggregate, type)
          return decode_hash(aggregate, entity_fields(entity), value) if entity

          value_object = Runtime::Value.value_object_for(aggregate, type)
          return value unless value_object

          decode_hash(aggregate, value_object.attributes.to_h { |field| [field.name, field] }, value)
        end

        # An entity is "structurally interchangeable with an aggregate"
        # (behaviour/entity.rb): its attributes plus its own lifecycle field.
        # Its value objects and nested entities resolve through the root
        # aggregate, the same way `EntityListCoercion#hydrate_entity_list`
        # resolves them.
        def entity_fields(entity)
          fields = entity.attributes.to_h { |attribute| [attribute.name, attribute] }
          lifecycle = entity.lifecycle
          fields[lifecycle.field.to_sym] = nil if lifecycle && !fields.key?(lifecycle.field.to_sym)
          fields
        end

        # ── decoded? ────────────────────────────────────────────────────

        # The mirror of `decode_hash`: a key `decode` would respell (any
        # non-Symbol at the top, a non-Symbol declared key below it) means
        # "not decoded"; an undeclared nested key keeps whatever spelling
        # it has, exactly as `decode` keeps it.
        def hash_decoded?(aggregate, fields, hash, top: false)
          hash.all? do |key, value|
            if key.is_a?(Symbol)
              !fields.key?(key) || field_decoded?(aggregate, fields[key], value)
            else
              !top && !fields.key?(key.to_s.to_sym)
            end
          end
        end

        def field_decoded?(aggregate, attribute, value)
          return true if attribute.nil? || value.nil? || attribute.reference?
          return composite_decoded?(aggregate, attribute.type.to_s, value) unless attribute.list?

          !value.is_a?(Array) || value.all? { |element| composite_decoded?(aggregate, attribute.type.to_s, element) }
        end

        def composite_decoded?(aggregate, type, value)
          return true unless value.is_a?(Hash)

          entity = Runtime::Value.find_entity(aggregate, type)
          return hash_decoded?(aggregate, entity_fields(entity), value) if entity

          value_object = Runtime::Value.value_object_for(aggregate, type)
          return true unless value_object

          hash_decoded?(aggregate, value_object.attributes.to_h { |field| [field.name, field] }, value)
        end
      end
    end
  end
end
