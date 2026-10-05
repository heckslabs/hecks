require "json"
require_relative "../../runtime/value"

module Hecks
  module Ports
    module Persistence
      # Canonical spelling of an aggregate's state across the store boundary;
      # every adapter's `encode`, `decode` and `copy` route through here.
      #
      # `decode` never invents or drops a declared key: absence must stay absence, since
      # defaults, era translation and required-field checks all key off it.
      module StateCodec
        JSON_SCALARS = [String, Integer, Float, TrueClass, FalseClass, NilClass].freeze

        module_function

        # Converts state into its canonical JSON-ready form for a durable adapter to write.
        #
        # @param _aggregate [Bluebook::Aggregate, Bluebook::Entity] unused; taken so `encode`
        #   and `decode` have one signature
        # @param state [Hash, Runtime::Value, nil] the state to store; nil for a delete entry
        # @return [Hash{String => Object}, nil] a new Hash with String keys at every depth and
        #   only JSON scalars, Arrays and Hashes below; nil when `state` is nil
        def encode(_aggregate, state) = encode_value(state)

        # Respells stored state into the declared shape by walking the aggregate's IR.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct whose
        #   declarations name the keys to symbolize
        # @param raw [Hash, Object, nil] parsed stored state, with keys in either spelling
        # @return [Hash{Symbol => Object}, Object, nil] a new Hash with every top-level key and
        #   every declared nested key a Symbol; anything that is not a Hash is returned as given
        def decode(aggregate, raw)
          return raw unless raw.is_a?(Hash)

          fields = declared_top_level(aggregate)
          decode_hash(aggregate, fields, raw, symbolize_undeclared: true)
        end

        # Deep-copies state into the shape a durable adapter would read back, without JSON text.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct whose
        #   declarations name the keys to symbolize
        # @param state [Hash, Runtime::Value, nil] live state, such as `Instance#state`
        # @return [Hash{Symbol => Object}, nil] `decode(encode(state))`, sharing no Hash or
        #   Array with `state`; nil when `state` is nil
        def copy(aggregate, state) = decode(aggregate, encode(aggregate, state))

        # Deep-copies one element of a `list_of` composite attribute, exactly as `copy` would
        # copy it inside its list.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct that declares
        #   the list attribute
        # @param attribute [Bluebook::Attribute] a list attribute of `aggregate`
        # @param element [Hash, Runtime::Value, Object] one element of the live list
        # @return [Hash, Object] a new decoded Hash sharing nothing with `element`; a leaf
        #   element is returned as its JSON round trip
        def copy_list_element(aggregate, attribute, element)
          decode_composite(aggregate, attribute.type.to_s, encode_value(element))
        end

        # Maps every declared top-level field name to its attribute.
        #
        # An attribute that shares a name with the lifecycle field or a projected field keeps
        # its declared type; an entity (no `projected_fields` of its own) gets its entity fields.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct to walk
        # @return [Hash{Symbol => Bluebook::Attribute, nil}] a new Hash of field name to
        #   attribute; nil marks the lifecycle field or a projected field with no attribute
        def declared_top_level(aggregate)
          fields = entity_fields(aggregate)
          return fields unless aggregate.respond_to?(:projected_fields)

          aggregate.projected_fields.each { |field| fields[field.name.to_sym] = nil unless fields.key?(field.name.to_sym) }
          fields
        end

        # Checks whether state already has the shape `decode` produces.
        #
        # `CodecBoundary` asks this of every `Instance` an adapter builds; a `Runtime::Value`
        # already is the declared shape, so it answers true without allocating.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct the state
        #   belongs to
        # @param state [Hash, Runtime::Value, nil] the state to inspect
        # @return [Boolean] true when `state` is decoded, and for anything that is not a Hash
        def decoded?(aggregate, state)
          return true unless state.is_a?(Hash)

          hash_decoded?(aggregate, declared_top_level(aggregate), state, top: true)
        end

        # Encodes one value, recursing through Hashes, Arrays and `Runtime::Value`s.
        #
        # @param value [Object] any state value; a `Runtime::Value` is encoded as its `to_h`
        # @return [Hash{String => Object}, Array, String, Integer, Float, Boolean, nil] the
        #   JSON-ready form; a leaf outside `JSON_SCALARS` (a Symbol, a Time) becomes whatever
        #   a `JSON.generate` then `JSON.parse` round trip makes of it
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

        # Decodes one Hash level, symbolizing its declared keys and recursing into their values.
        # Key order is kept; a string key is skipped when the symbol spelling is also present.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the root construct nested
        #   value objects and entities resolve through
        # @param fields [Hash{Symbol => Bluebook::Attribute, nil}] the fields declared at this level
        # @param raw [Hash] the stored Hash for this level
        # @param symbolize_undeclared [Boolean] true to symbolize undeclared keys too (the top
        #   level does); false to leave their spelling alone
        # @return [Hash] a new Hash in `raw`'s key order
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

        # Decodes the stored value of one declared field.
        #
        # A value object or entity recurses only when the stored value matches its declared
        # Hash/Array shape; anything else (a legacy bare scalar) is left for hydration.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the root construct, through
        #   which the field's type resolves
        # @param attribute [Bluebook::Attribute, nil] the field's declaration; nil for a
        #   lifecycle or projected field
        # @param value [Object, nil] the stored value
        # @return [Object, nil] `value` itself when nothing needs respelling, otherwise a new
        #   Hash or Array of decoded composites
        def decode_field(aggregate, attribute, value)
          return value if attribute.nil? || value.nil? || attribute.reference?

          if attribute.list?
            return value unless value.is_a?(Array)

            value.map { |element| decode_composite(aggregate, attribute.type.to_s, element) }
          else
            decode_composite(aggregate, attribute.type.to_s, value)
          end
        end

        # Decodes one stored value object or entity, looked up by type name.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the root construct that
        #   declares, or whose chapter declares, the type
        # @param type [String] the declared type name, such as `"Address"`
        # @param value [Object] the stored value
        # @return [Hash, Object] a new decoded Hash; `value` unchanged when it is not a Hash or
        #   `type` names neither an entity nor an unambiguous value object
        def decode_composite(aggregate, type, value)
          return value unless value.is_a?(Hash)

          entity = Runtime::Value.find_entity(aggregate, type)
          return decode_hash(aggregate, entity_fields(entity), value) if entity

          value_object = Runtime::Value.value_object_for(aggregate, type)
          return value unless value_object

          decode_hash(aggregate, value_object.attributes.to_h { |field| [field.name, field] }, value)
        end

        # Maps an entity's (or aggregate's) attribute names, plus its lifecycle field, to
        # their attributes.
        #
        # Nested value objects and entities resolve through the root aggregate, the same way
        # `EntityListCoercion#hydrate_entity_list` resolves them.
        #
        # @param entity [Bluebook::Entity, Bluebook::Aggregate] the construct to walk
        # @return [Hash{Symbol => Bluebook::Attribute, nil}] a new Hash of field name to
        #   attribute; nil marks a lifecycle field that no attribute declares
        def entity_fields(entity)
          fields = entity.attributes.to_h { |attribute| [attribute.name, attribute] }
          lifecycle = entity.lifecycle
          fields[lifecycle.field.to_sym] = nil if lifecycle && !fields.key?(lifecycle.field.to_sym)
          fields
        end

        # Checks one Hash level for keys `decode` would respell.
        # The mirror of `decode_hash`: an undeclared nested key keeps its own spelling.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the root construct nested
        #   types resolve through
        # @param fields [Hash{Symbol => Bluebook::Attribute, nil}] the fields declared at this level
        # @param hash [Hash] the Hash to inspect
        # @param top [Boolean] true for the top level, where every key must be a Symbol
        # @return [Boolean] true when this level and every declared composite below it is decoded
        def hash_decoded?(aggregate, fields, hash, top: false)
          hash.all? do |key, value|
            if key.is_a?(Symbol)
              !fields.key?(key) || field_decoded?(aggregate, fields[key], value)
            else
              !top && !fields.key?(key.to_s.to_sym)
            end
          end
        end

        # Checks the stored value of one declared field, the mirror of `decode_field`.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the root construct, through
        #   which the field's type resolves
        # @param attribute [Bluebook::Attribute, nil] the field's declaration; nil for a
        #   lifecycle or projected field
        # @param value [Object, nil] the value to inspect
        # @return [Boolean] true when `decode_field` would leave `value` as it is; always true
        #   for nil, a reference, an undeclared attribute, or a list that is not an Array
        def field_decoded?(aggregate, attribute, value)
          return true if attribute.nil? || value.nil? || attribute.reference?
          return composite_decoded?(aggregate, attribute.type.to_s, value) unless attribute.list?

          return true unless value.is_a?(Array)

          # The element type resolves once per list, not once per element.
          fields = :unresolved
          value.all? do |element|
            next true unless element.is_a?(Hash)

            fields = composite_fields(aggregate, attribute.type.to_s) if fields == :unresolved
            fields.nil? || hash_decoded?(aggregate, fields, element)
          end
        end

        # Checks one stored value object or entity, the mirror of `decode_composite`.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the root construct that
        #   declares, or whose chapter declares, the type
        # @param type [String] the declared type name
        # @param value [Object] the value to inspect
        # @return [Boolean] true when `value` is not a Hash, `type` names neither an entity nor
        #   an unambiguous value object, or every declared key in it is a Symbol
        def composite_decoded?(aggregate, type, value)
          return true unless value.is_a?(Hash)

          fields = composite_fields(aggregate, type)
          fields.nil? || hash_decoded?(aggregate, fields, value)
        end

        # Maps the declared keys of a stored value object or entity, looked up by type name.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the root construct that
        #   declares, or whose chapter declares, the type
        # @param type [String] the declared type name
        # @return [Hash{Symbol => Bluebook::Attribute, nil}, nil] the entity's fields, else the
        #   unambiguous value object's; nil when `type` names neither
        def composite_fields(aggregate, type)
          entity = Runtime::Value.find_entity(aggregate, type)
          return entity_fields(entity) if entity

          value_object = Runtime::Value.value_object_for(aggregate, type)
          value_object&.attributes&.to_h { |field| [field.name, field] }
        end
      end
    end
  end
end
