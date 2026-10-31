# frozen_string_literal: true

module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # The aggregate's name before a rename, which keeps the old name resolving.
        module Renaming
          # @param value [Object] the name the aggregate held before, as the attribute types it
          # @return [Object] the old name as stored
          def formerly_known_as_impl(value)
            @formerly_known_as = value
          end
        end
      end
    end
  end
end
