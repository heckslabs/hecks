require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # **What an entity does**. Extended, not included — an entity is a
      # class, so this is singleton behaviour.
      #
      # `settle` is reached from `absorb` rather than a constructor, because a declared
      # entity is built by subclassing.
      module Entity
        include Identified
        include Indexed
        include Owns

        # The hook `absorb` calls once every declared field is assigned.
        #
        # @return [Class] this entity's own class (a `Bluebook::Entity` subclass), self,
        #   once identity and indexes are derived
        def settle
          derive_identity
          index_declarations
          self
        end

        # Builds every by-name index this entity answers finders through.
        #
        # @return [void]
        def index_declarations
          index_attributes(@attributes)
          @commands_by_name = index_by_hecks_name(@commands)
          @queries_by_name  = index_by_hecks_name(@queries)
        end

        # Nested entities, structurally interchangeable with an aggregate's `entities`:
        # `Value::Coercion#for_attribute` and `EntityInterpreter` both read it (ADR 0026).
        #
        # @return [Array<Class>] this entity's own nested entities (each a `Bluebook::Entity`
        #   subclass), or `[]` if it declares none
        def entities = @entities || []

        # Stamps this entity as owner of its commands, queries and nested entities, so
        # verbs read `Banking::Account.Ledger.Deposit`. Separate from `settle` because
        # `declare` stamps after the owning subclass exists.
        #
        # @return [void]
        def stamp_children = stamp(@commands, @queries, @entities)
      end
    end
  end
end
