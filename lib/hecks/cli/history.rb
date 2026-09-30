# frozen_string_literal: true

require "json"
require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `bin/history` and `hecks history`: every journal entry a domain's
    # append-only adapters hold, as JSON, the full write history rather than the current head.
    module History
      module_function

      # Boots the domain `argv` names and prints its history as one JSON document.
      #
      # @param argv [Array<String>] the domain directory, first
      # @param program [String] the name the usage message calls this command by
      # @return [void]
      # @raise [SystemExit] when `argv` is empty
      def call(argv, program: "bin/history")
        domain = argv.first or abort "usage: #{program} <domain>"
        puts JSON.generate(document(Hecks.boot(domain).registry))
      end

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
