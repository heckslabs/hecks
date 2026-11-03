# frozen_string_literal: true

module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # The names an aggregate keeps: the name it held before a rename, which keeps the old name
        # resolving, and the command that creates its records, which a missing-record refusal names.
        module Renaming
          # @param value [Object] the name the aggregate held before, as the attribute types it
          # @return [Object] the old name as stored
          def formerly_known_as_impl(value)
            @formerly_known_as = value
          end

          # @param value [Object] the command's name, as the bluebook writes it (e.g. "Adr.draft!")
          # @return [Object] the command name as stored
          def created_by_impl(value)
            @created_by = value
          end
        end
      end
    end
  end
end
