require_relative "../../hecks"

module Hecks
  module CLI
    # The notice `hecks stores` and `hecks history` print when nothing is persisted. Hecks is in
    # Memory unless a local hecksagon opts it in (ADR 0136), so a fresh process holds no records and
    # no journal, and the plain JSON they print would read as an empty store rather than as a store
    # that was never kept.
    module PersistenceNotice
      module_function

      # Writes the notice to standard error when every aggregate of the booted domain is in Memory.
      # Standard error keeps standard output the JSON document the command promises.
      #
      # @param registry [Runtime::Registry] a booted domain's registry
      # @param program [String] the name the notice calls the command by
      # @return [void]
      def announce(registry, program:)
        warn "#{program}: #{message_for(registry)}" unless persisted?(registry)
      end

      # @param registry [Runtime::Registry] a booted domain's registry
      # @return [Boolean] whether any aggregate is bound to a store other than Memory
      def persisted?(registry)
        adapters(registry).any? { |adapter| adapter != Ports::Persistence::DEFAULT_ADAPTER }
      end

      # @param registry [Runtime::Registry] a booted domain's registry
      # @return [Array<String>] the adapter each aggregate of each bluebook resolves to
      def adapters(registry)
        registry.bluebooks.flat_map do |name, bluebook|
          bluebook.aggregates.map { |aggregate| Ports::Persistence::BindingPolicy.resolve(registry, name, aggregate).adapter }
        end
      end

      # @param registry [Runtime::Registry] a booted domain's registry
      # @return [String] what is true of this run and how to keep records instead
      def message_for(registry)
        "nothing is persisted: #{adapters(registry).size} aggregates are in Memory, so this process holds no " \
          "records and no history. To keep them, add a hecks.local.hecksagon with `persisted_by \"PostgresEra\"` " \
          "and a hecks.local.world with `default_database` (ADR 0136)."
      end
    end
  end
end
