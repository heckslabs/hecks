# frozen_string_literal: true

require "hecks"
# The translation and scaffold machinery lives in the era persistence plugin (ADR 0033).
require "hecks/ports/persistence/plugins/era"
require_relative "../tools"

module Hecks
  module Tools
    # Diffs the held era against the current bluebook into an edge file: confident rules inline,
    # ambiguities as `unresolved` lines to resolve by hand.
    #
    #   hecks scaffold_translation <domain>
    module TranslationScaffold
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
        first = bluebook.aggregates.first or abort "#{bluebook.name} declares no aggregates"
        adapter_name = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, first).adapter
        capable =
          begin
            adapter_class = registry.adapter_class(adapter_name)
            adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
          rescue StandardError
            false
          end
        # Eras belong to the adapters that can carry data across them. An edge scaffolded for an
        # adapter that cannot apply it would be a document nothing will ever run.
        unless capable
          abort "#{bluebook.name} is bound to #{adapter_name}, which holds no eras — " \
                "a translation edge is only applied by a lineage-capable adapter. " \
                "Bind PostgresEra, or change the shape and its stored data by hand."
        end

        scaffold(registry, bluebook, directory, adapter_name)
      end

      # @param domain_path [String] the domain directory
      # @return [Array] the registry, its bluebook and the bluebook directory
      def load_domain(domain_path)
        loading = Hecks::Ports::Loading.bootstrap
        directory = loading.bluebook_directory(domain_path)
        registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(loading.shared_root(nil, directory))
          # deliberately not translations/*.bluebook: an unresolved edge file refuses to load, and
          # regenerating it is this tool's whole job
          loading.load_each(directory, %w[*.port *.adapter])
          loading.load_bluebooks(directory)
          loading.load_each(directory, %w[*.hecksagon *.world])

          # A domain that splits `persisted_by` per environment declares none in its base
          # `.hecksagon`, so resolution fails without this overlay — opt-in via
          # HECKS_PROJECT_ENVIRONMENT, a no-op otherwise.
          if (target_environment = ENV.fetch("HECKS_PROJECT_ENVIRONMENT", nil))
            loading.load_each(directory, [File.join("environments", "#{target_environment}.hecksagon")])
            loading.load_each(directory, [File.join("environments", "#{target_environment}.world")])
          end
        end
        bluebook = registry.bluebooks.values.first or abort "no bluebook in #{directory}"
        [registry, bluebook, directory]
      end

      # @return [Integer] 0
      def scaffold(registry, bluebook, directory, adapter_name)
        current_shape = Hecks::Runtime::StorageShape.project(bluebook)
        manager = Hecks::Adapters::PostgresEra::LineageManager

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
        if lineage.eras.empty?
          lineage.hold_first!(Hecks::Runtime::EraCheck.source_text_for(bluebook, directory),
                              projection: current_shape)
          puts "#{bluebook.name} held era 1 just now — nothing to scaffold."
          return 0
        end
        latest = lineage.eras.last
        held_bluebook = manager.shadow(latest[:held_text])
        if Hecks::Runtime::StorageShape.project(held_bluebook) == current_shape
          puts "#{bluebook.name} matches era #{latest[:ordinal]} — nothing to scaffold."
          return 0
        end
        path = manager.scaffold!(registry, bluebook, lineage, latest, directory)
        diffed = Hecks::Translation::Scaffold.diff(held_bluebook, bluebook)
        db.close

        report(path, diffed)
        0
      end

      # @return [void]
      def report(path, diffed)
        text = File.read(path)
        unresolved = text.scan(/^\s*unresolved /).size
        unclaimed = diffed ? diffed[:unclaimed] : []
        puts "wrote #{path}"
        unclaimed.each do |name|
          puts "UNCLAIMED: #{name} existed and now doesn't, and its successor is ambiguous — " \
               "add `aggregate \"NewName\", was: #{name.inspect}` (with its rules) or " \
               "`retired #{name.inspect}` by hand."
        end
        if unresolved.zero? && unclaimed.empty?
          puts "0 unresolved — this shape change costs one extra boot and no typing. " \
               "Check it with hecks audit_translation, then boot."
        elsif unresolved.positive?
          puts "#{unresolved} unresolved — decide what each became (rename/move/convert/drop, or " \
               "compute on PostgresEra), then boot."
        end
      end
    end
  end
end
