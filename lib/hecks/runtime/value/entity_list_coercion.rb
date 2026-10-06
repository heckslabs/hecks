require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../../rendering"

module Hecks
  module Runtime
    class Value
      # Hydrates a `list_of` attribute's own elements, entity-typed and
      # value-object-typed alike; extended into `Value` alongside `Coercion`.
      module EntityListCoercion
        # Searches the whole entity tree, not just the root's direct
        # children; `aggregate` here is always the root aggregate. (ADR 0026)
        def find_entity(construct, name)
          construct.entities.each do |candidate|
            return candidate if candidate.hecks_name == name

            found = find_entity(candidate, name)
            return found if found
          end
          nil
        end

        # Hydrates a `list_of` attribute's offered value: each element of a
        # whole-list Array, or a single remove-target value.
        #
        # Delegates non-entity types to `hydrate_value_object_list` so
        # elements get the same `pattern:`/invariant checks other
        # composites get. (ADR 0047)
        def hydrate_entity_list(aggregate, attribute, value)
          entity = find_entity(aggregate, attribute.type.to_s)
          return hydrate_value_object_list(aggregate, attribute, value) unless entity

          return hydrate_entity_identity(aggregate, entity, value) unless value.is_a?(Array)

          hydrated = value.map { |element| hydrate_entity_element(aggregate, entity, element) }
          # Only a genuine whole-list offering names every element's own
          # identity at once; a single `remove:` target never reaches this.
          check_entity_list_identities(aggregate, entity, hydrated)
          Freezer.deep(hydrated)
        end

        # Refuses a whole-list offering that misnames its own entities: a
        # duplicate identity across two elements, or an element missing
        # one. Single-field identities only; skipped once
        # `trusting_stored_state?`.
        def check_entity_list_identities(aggregate, entity, elements)
          identity = entity.identified_by
          return unless identity
          return if trusting_stored_state?

          seen = []
          elements.grep(Hash).each do |fields|
            offered = fields[identity]
            numeric_field_mismatch!(entity.hecks_name, identity, entity.attribute(identity)&.type, "nil") if offered.nil?
            refuse_duplicate_identity!(aggregate, entity, offered) if seen.include?(offered)
            seen << offered
          end
        end

        # Coerces a `remove:` target against an entity's single-field
        # identity type, rather than the entity's full shape. Passed
        # through unchanged for a composite identity (more than one head)
        # rather than guessing which head it means.
        def hydrate_entity_identity(aggregate, entity, value)
          return value if value.is_a?(self)

          heads = entity.identity_heads
          return value unless heads.one?

          field = entity.attribute(heads.first)
          return value unless field

          for_attribute(aggregate, field, value)
        end

        # Hydrates a `list_of` attribute's offered value when
        # `attribute.type` names a value object rather than an entity.
        #
        # Branches on `value.is_a?(Array)` rather than `Array(value)`: a
        # bare Hash-shaped single target would otherwise be shredded into
        # its own `[[k, v], ...]` pairs instead of hydrated whole.
        def hydrate_value_object_list(aggregate, attribute, value)
          return value unless aggregate.respond_to?(:value_object)

          value_object = value_object_for(aggregate, attribute.type)
          return value unless value_object

          return hydrate_value_object_element(aggregate, attribute, value_object, value) unless value.is_a?(Array)

          hydrated = value.map { |element| hydrate_value_object_element(aggregate, attribute, value_object, element) }
          Freezer.deep(hydrated)
        end

        # Rebuilds one `list_of` element into a real, validated `Value`,
        # unless it already is one of `value_object`'s own type.
        def hydrate_value_object_element(aggregate, attribute, value_object, element)
          return element if element.is_a?(self) && element.type_name == value_object.hecks_name

          build(value_object, fields_for(value_object, attribute.name, element), aggregate)
        end

        private

        # One element of an entity list, each field coerced through its declared attribute.
        def hydrate_entity_element(aggregate, entity, element)
          return element unless element.is_a?(Hash)

          element.each_with_object({}) do |(name, field_value), acc|
            key = name.to_sym
            field = entity.attribute(key)
            acc[key] = field ? for_attribute(aggregate, field, field_value) : field_value
          end
        end

        def refuse_duplicate_identity!(aggregate, entity, offered)
          raise AlreadyExists,
                RefusalWording.render_site("AlreadyExists", "entity_duplicate",
                                           entity: entity.hecks_name, aggregate: aggregate.hecks_name,
                                           identity: entity.identity_paths.join(", "),
                                           offered: [Rendering.describe(offered)])
        end
      end
    end
  end
end
