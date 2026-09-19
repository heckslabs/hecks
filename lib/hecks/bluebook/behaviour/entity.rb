require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # **What an entity does**. Extended, not included — an entity is a
      # class, so this is singleton behaviour.
      #
      # `settle` is the same seam an Aggregate has, reached from `absorb`
      # rather than from a constructor because a declared entity is built
      # by subclassing rather than by `new`. The traits are the same
      # ones, which is the whole point of them being traits: an entity's
      # identity is derived exactly as an aggregate's is, and was written
      # out twice before anyone could see that.
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

        # S17, ADR 0026 — `@entities`, now genuinely nested entities
        # (Dispatch, inside Handler) rather than always `[]`. Kept as a
        # real reader rather than a hardcoded empty list for two
        # reasons at once: `Value::Coercion#for_attribute` calls
        # `.entities` on whatever owner it is handed — an aggregate's or
        # an entity's own — the moment it meets any `list_of(...)`
        # attribute (entity-typed or not — `hydrate_entity_list`'s own
        # fallback, `return value unless entity`, only runs once
        # `.entities` has already answered) ; and `EntityInterpreter`
        # now walks a dotted chain of entities one level at a time
        # (`walk_entity_chain`) exactly the way an aggregate's own
        # `.entities` is walked for its direct children. Entity's own
        # header comment already promises it stays "structurally
        # interchangeable with an aggregate" for exactly this reason.
        #
        # @return [Array<Class>] this entity's own nested entities (each a `Bluebook::Entity`
        #   subclass), or `[]` if it declares none
        def entities = @entities || []

        # A piece owns the verbs declared on it, so they can state an
        # identity — `Banking::Account.Ledger.Deposit` rather than a
        # command that cannot say what it belongs to. Separate from
        # `settle` because `declare` stamps after absorbing, once the
        # subclass that will own them exists. `@entities` too now
        # (S17, ADR 0026) — a nested entity states its own owner chain
        # exactly the way a nested command does.
        #
        # @return [void]
        def stamp_children = stamp(@commands, @queries, @entities)
      end
    end
  end
end
