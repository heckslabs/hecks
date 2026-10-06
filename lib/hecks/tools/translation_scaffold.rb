# frozen_string_literal: true

require "hecks"
# The translation and scaffold machinery lives in the era persistence plugin (ADR 0033).
require "hecks/ports/persistence/plugins/era"
require_relative "../tools"
require_relative "translation_scaffold/reporting"

module Hecks
  module Tools
    # Diffs the held era against the current bluebook into an edge file: confident rules inline,
    # ambiguities as `unresolved` lines to resolve by hand.
    #
    #   hecks scaffold_translation <domain>
    module TranslationScaffold
      extend Reporting

      module_function

      # Writes the edge file and prints what is left to decide.
      #
      # @param argv [Array<String>] the domain directory
      # @param root [String] unused: the domain is read from the path given
      # @return [Integer] 0
      # @raise [SystemExit] when the domain cannot be loaded or its adapter holds no eras
      def main(argv, **)
        argv = argv.dup
        domain_path = argv.shift or abort "usage: hecks scaffold_translation <domain>"

        registry, bluebook, directory = load_domain(domain_path)
        scaffold(registry, bluebook, directory, bound_adapter(registry, bluebook))
      end

      # @return [String] the name of the adapter the domain is bound to
      # @raise [SystemExit] when that adapter is not lineage-capable
      def bound_adapter(registry, bluebook)
        first = bluebook.aggregates.first or abort "#{bluebook.name} declares no aggregates"
        adapter_name = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, first).adapter
        # Eras belong to the adapters that can carry data across them. An edge scaffolded for an
        # adapter that cannot apply it would be a document nothing will ever run.
        unless lineage_capable?(registry, adapter_name)
          abort "#{bluebook.name} is bound to #{adapter_name}, which holds no eras — " \
                "a translation edge is only applied by a lineage-capable adapter. " \
                "Bind PostgresEra, or change the shape and its stored data by hand."
        end
        adapter_name
      end

      def lineage_capable?(registry, adapter_name)
        adapter_class = registry.adapter_class(adapter_name)
        adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
      rescue StandardError
        false
      end

      # @param domain_path [String] the domain directory
      # @return [Array] the registry, its bluebook and the bluebook directory
      def load_domain(domain_path)
        loading = Hecks::Ports::Loading.bootstrap
        directory = loading.bluebook_directory(domain_path)
        registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
        Hecks.with_registry(registry) { load_chapters(loading, directory) }
        bluebook = registry.bluebooks.values.first or abort "no bluebook in #{directory}"
        [registry, bluebook, directory]
      end

      # Loads the library, the project and the domain's files into the registry in scope.
      def load_chapters(loading, directory)
        loading.load_library
        loading.load_project(loading.shared_root(nil, directory))
        # deliberately not translations/*.bluebook: an unresolved edge file refuses to load, and
        # regenerating it is this tool's whole job
        loading.load_each(directory, %w[*.port *.adapter])
        loading.load_bluebooks(directory)
        loading.load_each(directory, %w[*.hecksagon *.world])
        load_environment_overlay(loading, directory)
      end

      # A domain that splits `persisted_by` per environment declares none in its base
      # `.hecksagon`, so resolution fails without this overlay — opt-in via
      # HECKS_PROJECT_ENVIRONMENT, a no-op otherwise.
      def load_environment_overlay(loading, directory)
        target_environment = ENV.fetch("HECKS_PROJECT_ENVIRONMENT", nil) or return

        loading.load_each(directory, [File.join("environments", "#{target_environment}.hecksagon")])
        loading.load_each(directory, [File.join("environments", "#{target_environment}.world")])
      end

      # @return [Integer] 0
      def scaffold(registry, bluebook, directory, adapter_name)
        current_shape = Hecks::Runtime::StorageShape.project(bluebook)
        db, lineage = open_lineage(registry, bluebook, adapter_name)
        return hold_first_era(lineage, bluebook, directory, current_shape) if lineage.eras.empty?

        latest, held_bluebook = held_era(lineage)
        return matches_era(bluebook, latest) if Hecks::Runtime::StorageShape.project(held_bluebook) == current_shape

        path = lineage_manager.scaffold!(registry, bluebook, lineage, latest, directory)
        diffed = Hecks::Translation::Scaffold.diff(held_bluebook, bluebook)
        db.close

        report(path, diffed)
        0
      end

      def lineage_manager
        Hecks::Adapters::PostgresEra::LineageManager
      end

      # @return [Array] the open connection and its ensured lineage
      def open_lineage(registry, bluebook, adapter_name)
        # `World#for_binding` keys settings by the world-declared adapter name (e.g.
        # "PostgresEra"); a bypassed name like "Postgres" finds nothing.
        settings = registry.world(bluebook.name)&.for_binding(Hecks::Ports::Persistence::VERB, adapter_name) || {}
        # A Shared-mode domain's `.world` file declares no schema of its own — production is scoped
        # by the Lambda's own HECKS_SCHEMA. Run by hand outside Lambda, this tool needs that same
        # schema supplied the same way.
        settings = settings.merge(schema: ENV["HECKS_SCHEMA"]) if ENV["HECKS_SCHEMA"]
        db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, settings)
        lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
        lineage.ensure_base!
        [db, lineage]
      end

      # @return [Array] the journal's latest era and the bluebook it held
      def held_era(lineage)
        latest = lineage.eras.last
        [latest, lineage_manager.shadow(latest[:held_text])]
      end

      # A journal with no era yet holds the bluebook as its first, so there is nothing to scaffold.
      #
      # @return [Integer] 0
      def hold_first_era(lineage, bluebook, directory, current_shape)
        lineage.hold_first!(Hecks::Runtime::EraCheck.source_text_for(bluebook, directory),
                            projection: current_shape)
        puts "#{bluebook.name} held era 1 just now — nothing to scaffold."
        0
      end

      # @return [Integer] 0
      def matches_era(bluebook, latest)
        puts "#{bluebook.name} matches era #{latest[:ordinal]} — nothing to scaffold."
        0
      end
    end
  end
end
