module Hecks
  module Bluebook
    module DSL
      class CommandBuilder
        # What a command is declared on and what it can reach there: the owning aggregate or
        # entity's name, its givens, attributes and constructs, and the aggregate-wide pool of
        # entity-level givens that a piece-owned command's bare reference also consults.
        Owner = Struct.new(:owner, :named_givens, :owner_attributes, :owner_constructs,
                           :entity_shared_givens, keyword_init: true) do
          # Builds an `Owner` with every field defaulted to empty, refusing an unknown keyword.
          #
          # @param context [Hash] any of the struct's own fields
          # @return [Owner] the owner, with a fresh empty collection for each field left out
          def self.from(**context)
            new(owner: nil, named_givens: {}, owner_attributes: [], owner_constructs: [],
                entity_shared_givens: {}, **context)
          end
        end
      end
    end
  end
end
