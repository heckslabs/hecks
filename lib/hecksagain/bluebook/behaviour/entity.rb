require_relative "traits"

module Hecksagain
  class Bluebook
    module Behaviour
      # WHAT AN ENTITY DOES. EXTENDED, not included — an entity is a
      # CLASS, so this is singleton behaviour.
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

        def settle
          derive_identity
          index_declarations
          self
        end

        def index_declarations
          index_attributes(@attributes)
          @commands_by_name = index_by_hecks_name(@commands)
          @queries_by_name  = index_by_hecks_name(@queries)
        end

        # A piece OWNS the verbs declared on it, so they can state an
        # identity — `Banking::Account.Ledger.Deposit` rather than a
        # command that cannot say what it belongs to. Separate from
        # `settle` because `declare` stamps AFTER absorbing, once the
        # subclass that will own them exists.
        def stamp_children = stamp(@commands, @queries)
      end
    end
  end
end
