# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Backfills `hecks_eras.held_projection` for rows that predate it, by calling the same path
    # `EraStore#eras` already takes on boot, explicitly. Idempotent.
    #
    #   hecks backfill_projections <domain path>
    module EraProjectionBackfill
      module_function

      # Backfills the rows that carry no projection and prints how many it fixed.
      #
      # @param argv [Array<String>] the domain directory
      # @param root [String] unused: the domain is read from the path given
      # @return [Integer] 0, or 1 when a row fails its own integrity check
      # @raise [SystemExit] when the domain cannot be loaded or its adapter holds no eras
      def main(argv, **)
        domain_path = argv.first
        abort "usage: hecks backfill_projections <domain path>" unless domain_path

        registry, bluebook = load_domain(domain_path)
        backfill(bluebook, lineage_settings(registry, bluebook))
      end

      # @param domain_path [String] the domain directory
      # @return [Array] the registry and its bluebook
      def load_domain(domain_path)
        loading = Hecks::Ports::Loading.bootstrap
        directory = loading.bluebook_directory(domain_path)
        registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(loading.shared_root(nil, directory))
          loading.load_each(directory, %w[*.port *.adapter *.bluebook *.hecksagon *.world])
        end

        bluebook = registry.bluebooks.values.first or abort "no bluebook in #{directory}"
        [registry, bluebook]
      end

      # @return [Hash] the persistence binding's settings
      # @raise [SystemExit] when the bound adapter holds no eras
      def lineage_settings(registry, bluebook)
        first = bluebook.aggregates.first or abort "#{bluebook.name} declares no aggregates"
        adapter_name = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, first).adapter
        # Only a lineage-capable adapter holds eras — every other adapter has no held_projection
        # column to migrate.
        unless lineage_capable?(registry, adapter_name)
          abort "#{bluebook.name} is bound to #{adapter_name}, which holds no eras — nothing to migrate."
        end

        registry.binding_settings(bluebook.name, Hecks::Ports::Persistence::VERB, adapter_name)
      end

      def lineage_capable?(registry, adapter_name)
        adapter_class = registry.adapter_class(adapter_name)
        adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
      rescue StandardError
        false
      end

      # @return [Integer] the exit status
      def backfill(bluebook, settings)
        db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, settings)
        lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
        lineage.ensure_base!

        before = missing_projections(db, bluebook)
        return nothing_to_do(bluebook) if before.zero?
        return 1 unless rows_intact?(bluebook, lineage)

        backfilled = before - missing_projections(db, bluebook)
        puts "#{bluebook.name}: backfilled #{backfilled} era#{"s" unless backfilled == 1} — " \
             "every row now carries a projection."
        0
      end

      # @return [Integer] how many of the domain's era rows carry no projection
      def missing_projections(db, bluebook)
        db.exec_params(
          "SELECT count(*)::int AS n FROM hecks_eras WHERE domain = $1 AND held_projection IS NULL",
          [bluebook.name]
        )[0]["n"].to_i
      end

      # @return [Integer] 0
      def nothing_to_do(bluebook)
        puts "#{bluebook.name}: every held era already carries a projection — nothing to do."
        0
      end

      # Reading the eras backfills them, and raises on the first row whose own digest check fails —
      # a tampered row, not a merely legacy one, which backfilling must not paper over.
      #
      # @return [Boolean] false, after printing why, when a row fails its own integrity check
      def rows_intact?(bluebook, lineage)
        lineage.eras
        true
      rescue Hecks::Runtime::WiringError => e
        puts "#{bluebook.name}: stopped at a row that isn't merely legacy — it fails its own integrity check:"
        puts "  #{e.message}"
        puts "  resolve that first (see hecks reattest), then run this again for the remaining rows."
        false
      end
    end
  end
end
