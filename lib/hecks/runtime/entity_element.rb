require_relative "../naming"
require_relative "../freezer"
require_relative "value"
require_relative "refusal_wording"
require_relative "errors"
require_relative "identity"
require_relative "instance"
require_relative "entity_element/location"
require_relative "entity_element/mutations"

module Hecks
  module Runtime
    # Locates and mutates one entity element within an aggregate record — the shared
    # implementation behind EntityInterpreter and CommandInterpreter's own delegation.
    module EntityElement
      extend Location
      extend Mutations

      module_function

      # A sentinel that never equals a stored element field, since a real field can hold nil.
      UNMATCHABLE = Object.new.freeze
      private_constant :UNMATCHABLE

      # Fills every declared attribute `fields` does not already hold with its own
      # default (Instance.default_for), matching a freshly created aggregate's own
      # per-attribute defaults. Additive only: an existing key in `fields` is kept.
      def fill_declared_defaults(aggregate, entity, fields)
        entity.attributes.each do |attribute|
          next if fields.key?(attribute.name)

          fields[attribute.name] = attribute.list? ? Freezer.deep([]) : Instance.default_for(aggregate, attribute)
        end
        fields
      end

      # The match rule `remove:` uses against one stored list element. Whole-value
      # equality for a non-entity-typed list; for an entity-typed one, matches by its
      # single identity head (a composite or absent identity never matches).
      def list_element_match?(aggregate, attribute, element, value)
        entity = attribute&.list? ? Value.find_entity(aggregate, attribute.type.to_s) : nil
        return element == value unless entity

        head = entity.identity_heads.one? ? entity.identity_heads.first : nil
        return false unless head

        element.is_a?(Hash) && element[head] == value
      end

      # Refuses a caller-supplied or composite identity that already names an element
      # in `current`. Shared by the aggregate-owned and entity-owned append paths so
      # neither reimplements the check. `owner` is named in the refusal only.
      def check_entity_collision(owner, entity, current, fields)
        heads = entity.identity_heads
        return if heads.empty?

        collision = Array(current).find { |element| heads.all? { |head| element[head] == fields[head] } }
        return unless collision

        raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "entity_duplicate",
                                                        entity: entity.hecks_name, aggregate: owner.hecks_name,
                                                        identity: Identity.reading(entity),
                                                        offered: heads.map { |head| Rendering.describe(fields[head]) }))
      end
    end
  end
end
