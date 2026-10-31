# frozen_string_literal: true

module Hecks
  module Adapters
    class SettingsReading
      # The store rows of `hecks config`: each loaded bluebook's store, and the aggregates whose own
      # bind overrides it. Resolved through the runtime's binding policy, so these rows cannot
      # disagree with a boot.
      module Stores
        # The adapter names the store rows recognise by their storage.
        SQLITE = /Sqlite/
        POSTGRES = /Postgres/

        # cannot disagree with a boot.
        def stores(directory)
          registry = Hecks.describe(directory).registry
          registry.bluebooks.each_value.flat_map { |declaration| store_rows(registry, declaration) }
        rescue StandardError => e
          [["store", "could not be read", first_line(e.message)]]
        end

        def store_rows(registry, declaration)
          name = declaration.name
          adapter = registry.default_adapter_for(name) || Ports::Persistence::BindingPolicy.inherited_adapter(registry,
                                                                                                              name) || DEFAULT
          [["store #{name}", store_of(registry, name, adapter), default_store_source(registry, name)],
           *aggregate_store_rows(registry, declaration)]
        end

        def aggregate_store_rows(registry, declaration)
          declaration.aggregates.filter_map do |aggregate|
            next unless bound_here?(registry, declaration.name, aggregate)

            bind = Ports::Persistence::BindingPolicy.resolve(registry, declaration.name, aggregate)
            ["store #{declaration.name}::#{aggregate.name}", store_of(registry, declaration.name, bind.adapter),
             "aggregate bind in the hecksagon"]
          end
        end

        def bound_here?(registry, domain, aggregate)
          registry.hecksagon(domain)&.binds&.any? { |bind| bind.aggregate == aggregate.hecks_name && bind.verb == VERB } || false
        end

        def default_store_source(registry, name)
          return "hecksagon" if registry.hecksagon(name)&.default_binds(VERB)&.any?
          return "world default_adapter" if registry.default_adapter_for(name)
          return "attaching domain's root default" if Ports::Persistence::BindingPolicy.inherited_adapter(registry, name)

          "default"
        end

        def store_of(registry, domain, adapter)
          settings = registry.binding_settings(domain, VERB, adapter)
          case adapter
          when DEFAULT then DEFAULT
          when SQLITE then "SqliteAt #{settings[:database]}"
          when POSTGRES then "Postgres #{database_name(settings[:database])}"
          else adapter
          end
        end

        # The database's name from a URL, with the password hidden and the query string left out.
        def database_name(url)
          without_query = hide_password(url).split("?").first.to_s
          without_query.split("/").last.to_s
        end
      end
    end
  end
end
