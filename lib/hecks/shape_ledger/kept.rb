# frozen_string_literal: true

module Hecks
  module ShapeLedger
    # The one rule for whether a bluebook's data is kept: data Hecks must protect with an era or a
    # translation edge, against data it may drop (ADR 0190). A bluebook is kept when it is a
    # framework member, which clients persist, or when its committed world binds an era-managed
    # store and does not mark it `disposable_ledger`. Every other bluebook is disposable.
    #
    # The rule reads the committed world only, so a `*.local.world` that opts a copy into SQLite or
    # Postgres never makes data kept. The target IR exports its answer as the `kept` key, which the
    # Rust host reads, so both runtimes answer the same.
    module Kept
      module_function

      # @param registry [Runtime::Registry] a registry loaded from the committed world
      # @param name [String] the bluebook's name
      # @param bluebook [Bluebook::Declaration] the bluebook
      # @return [Boolean] whether its data is kept
      def of?(registry, name, bluebook)
        return true if Framework.members.key?(name)

        era_managed?(registry, adapter_of(registry, name, bluebook)) && !disposable?(registry, name)
      end

      # @param registry [Runtime::Registry] a registry loaded from the committed world
      # @param name [String] the bluebook's name
      # @param bluebook [Bluebook::Declaration] the bluebook
      # @return [String] the adapter its first aggregate binds, `"Memory"` for a bluebook with none
      def adapter_of(registry, name, bluebook)
        first = bluebook.aggregates.first
        first ? Runtime::RevisionCheck.adapter_for(registry, name, first) : Ports::Persistence::DEFAULT_ADAPTER
      end

      # @param registry [Runtime::Registry] a registry loaded from the committed world
      # @param adapter [String] an adapter's name
      # @return [Boolean] whether the adapter carries eras
      def era_managed?(registry, adapter) = Runtime::RevisionCheck.lineage_capable?(registry, adapter)

      # @param registry [Runtime::Registry] a registry loaded from the committed world
      # @param name [String] the bluebook's name
      # @return [Boolean] whether the committed world marks the bluebook's era store disposable
      def disposable?(registry, name)
        settings = registry.binding_settings(name, Ports::Persistence::VERB, "PostgresEra")
        [true, "true"].include?(settings[:disposable_ledger])
      end
    end
  end
end
