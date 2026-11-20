# frozen_string_literal: true

require "json"
require "hecks"

module Hecks
  module Adapters
    class InProcessBoot
      # Every journal entry a domain's append-only adapters hold, for `Introspection.History`: the
      # full write history rather than the current head.
      module History
        module_function

        # @param registry [Runtime::Registry] a booted domain's registry
        # @return [Hash{String => Array<Hash>}] each aggregate's storage name mapped to its entries
        def document(registry)
          registry.bluebooks.each_with_object({}) do |(name, bluebook), all|
            bluebook.aggregates.each do |aggregate|
              all[aggregate.storage_name] = entries(registry.repository(name, aggregate))
            end
          end
        end

        # @param repository [Object] an aggregate's repository
        # @return [Array<Hash{String => Object}>] its journal entries; empty
        #   when it is not append-only
        def entries(repository)
          return [] unless repository.is_a?(Ports::Persistence::AppendOnly)

          repository.entries.map { |entry| { "operation" => entry.operation, "id" => entry.id, "state" => entry.state } }
        end
      end
    end
  end
end
