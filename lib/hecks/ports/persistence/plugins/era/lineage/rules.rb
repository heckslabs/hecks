module Hecks
  module Ports
    module Persistence
      class Lineage
        # The optional rule lists a translation edge carries beyond the four positional ones;
        # an unknown keyword raises ArgumentError.
        #
        # - `retypes` — type names meaning the same shape
        # - `computes` — SQL-only rules, never applied in process
        # - `rekeys` — SQL rewrites of identity; only the first is read
        # - `backfills` — defaults for a new attribute
        # - `ancestor_name` — the aggregate's name before the edge, if renamed
        # - `ancestor_storage_name` — snake_case storage name of `ancestor_name`
        Rules = Struct.new(:retypes, :computes, :rekeys, :backfills, :ancestor_name, :ancestor_storage_name,
                           keyword_init: true) do
          # Builds the rules with every list defaulting to empty.
          #
          # @param given [Hash] any of the members; an unknown key raises ArgumentError
          # @return [Rules]
          def self.build(**given) = new(retypes: [], computes: [], rekeys: [], backfills: [], **given)
        end
      end
    end
  end
end
