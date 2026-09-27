require "json"
require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `bin/stores` and `hecks stores`: every aggregate's current
    # records as JSON (the head, not the journal — see `bin/history` for that).
    module Stores
      module_function

      # Boots the domain `argv` names and prints its stores as one JSON document.
      #
      # @param argv [Array<String>] the domain directory, first
      # @param program [String] the name the error message calls this command by
      # @return [void]
      # @raise [IndexError] when `argv` is empty
      # @raise [SystemExit] when the domain directory does not exist
      def call(argv, program:)
        domain = argv.fetch(0)
        unless Dir.exist?(domain)
          warn "#{program}: no such domain #{domain.inspect}"
          exit 1
        end

        registry = Hecks.boot(domain).registry
        stores = registry.bluebooks.each_with_object({}) do |(name, bluebook), all|
          bluebook.aggregates.each do |aggregate|
            all[aggregate.storage_name] = data_for(registry.repository(name, aggregate))
          end
        end

        puts JSON.generate(stores)
      end

      # Reads one aggregate's current records as plain JSON-ready hashes, ordered by id.
      #
      # @param repository [Ports::Persistence::AppendOnly] the aggregate's repository
      # @return [Array<Hash{String => Object}>] one hash per stored `Runtime::Instance`,
      #   sorted by id; `[]` when the aggregate has no records
      def records(repository)
        repository.all.sort_by(&:id).map { |instance| JSON.parse(JSON.generate(instance.to_h)) }
      end

      # Shapes one aggregate's dump for the top-level stores document.
      #
      # @param repository [Ports::Persistence::AppendOnly] the aggregate's repository
      # @return [Hash{String => Object}] `"authoritative"` mapped to `records(repository)`
      def data_for(repository)
        { "authoritative" => records(repository) }
      end
    end
  end
end
