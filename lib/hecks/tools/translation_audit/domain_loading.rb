# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module TranslationAudit
      # Loads the domain to audit and opens its lineage journal.
      module DomainLoading
        # @param domain_path [String] the domain directory
        # @return [Array] the registry, its bluebook and the bluebook directory
        def load_domain(domain_path)
          loading = Hecks::Ports::Loading.bootstrap
          directory = loading.bluebook_directory(domain_path)
          registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
          load_chapters(registry, loading, directory)
          bluebook = registry.bluebooks.values.first or abort "no bluebook in #{directory}"
          [registry, bluebook, directory]
        end

        # @param registry [Hecks::Runtime::Registry] the loaded registry
        # @param bluebook [Object] the domain's bluebook
        # @return [Array] the open connection and its ensured lineage
        # @raise [SystemExit] when the bound adapter is not lineage-capable
        def open_lineage(registry, bluebook)
          first = bluebook.aggregates.first or abort "#{bluebook.name} declares no aggregates"
          adapter_name = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, first).adapter
          refuse_unless_lineage_capable(registry, bluebook, adapter_name)

          db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, binding_settings(registry, bluebook, adapter_name))
          lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
          lineage.ensure_base!
          [db, lineage]
        end

        private

        def load_chapters(registry, loading, directory)
          Hecks.with_registry(registry) do
            loading.load_library
            loading.load_project(loading.shared_root(nil, directory))
            # Passes an environment overlay to `load_domain`, as `scaffold_translation` does.
            loading.load_domain(directory, environment: ENV.fetch("HECKS_PROJECT_ENVIRONMENT", nil))
          end
        rescue Hecks::Bluebook::DSL::Malformed => e
          abort "REFUSED at load: #{e.message}"
        end

        def refuse_unless_lineage_capable(registry, bluebook, adapter_name)
          return if lineage_capable?(registry, adapter_name)

          abort "the audit reads a lineage journal; #{bluebook.name} is bound to #{adapter_name}, " \
                "not PostgresEra"
        end

        def lineage_capable?(registry, adapter_name)
          adapter_class = registry.adapter_class(adapter_name)
          adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
        rescue StandardError
          false
        end

        def binding_settings(registry, bluebook, adapter_name)
          settings = registry.world(bluebook.name)&.for_binding(Hecks::Ports::Persistence::VERB, adapter_name) || {}
          # The same `HECKS_SCHEMA` support as `scaffold_translation`.
          ENV["HECKS_SCHEMA"] ? settings.merge(schema: ENV["HECKS_SCHEMA"]) : settings
        end
      end
    end
  end
end
