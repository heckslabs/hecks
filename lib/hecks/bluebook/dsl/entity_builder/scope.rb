module Hecks
  module Bluebook
    module DSL
      class EntityBuilder
        # What a piece is handed by whatever declares it, threaded unchanged through every nested
        # piece so siblings share the same pools: the owner's value objects and givens, the
        # naming of identity value objects, and the chapter-wide entity-given pools.
        Scope = Struct.new(:owner_value_objects, :owner_named_givens, :identity_name_prefix,
                           :identity_value_object_installer, :aggregate_name,
                           :chapter_entity_named_givens, :chapter_entity_pending_givens,
                           keyword_init: true) do
          # Builds a `Scope` with every field defaulted to empty, refusing an unknown keyword.
          #
          # @param context [Hash] any of the struct's own fields
          # @return [Scope] the scope, with a fresh empty collection for each field left out
          def self.from(**context)
            new(owner_value_objects: [], owner_named_givens: {}, identity_name_prefix: nil,
                identity_value_object_installer: nil, aggregate_name: nil,
                chapter_entity_named_givens: {}, chapter_entity_pending_givens: [], **context)
          end
        end
      end
    end
  end
end
