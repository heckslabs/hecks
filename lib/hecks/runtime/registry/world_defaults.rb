module Hecks
  module Runtime
    class Registry
      # The `default_database`/`default_adapter` a `.world` declares once for every chapter;
      # resolved most-specific-first (own bind, own world, project world) and never written back.
      module WorldDefaults
        # The default database only reaches a persistence bind whose adapter declares a
        # `database` field; a `database` the chapter's own settings name always wins.
        def binding_settings(domain, verb, adapter)
          declared = world(domain)&.for_binding(verb, adapter) || {}
          database = default_database_for(domain)
          return declared unless database && default_database_applies?(verb, adapter)

          { adapter: adapter.to_s, database: database }.merge(declared)
        end

        def default_adapter_for(domain) = world_default(domain, :default_adapter)

        def default_database_for(domain) = world_default(domain, :default_database)

        def verify_world_defaults!
          @declared.worlds.each_value do |declared|
            name = declared.default_adapter
            next unless name

            verify_default_adapter_named!(declared.domain, name)
          end
          self
        end

        private

        # The chapter's own world answers first; the project's world fills the gap.
        def world_default(domain, field)
          world(domain)&.public_send(field) || project_world&.public_send(field)
        end

        # The world of the first chapter this registry loaded — the target of a boot, ahead of
        # any framework member it attaches.
        def project_world = world(@declared.bluebooks.keys.first || @declared.worlds.keys.first)

        def default_database_applies?(verb, adapter)
          verb.to_s == Ports::Persistence::VERB && @declared.adapters[adapter.to_s]&.declares?(:database)
        end

        def verify_default_adapter_named!(domain, name)
          check_verb(Bluebook::Bind.new(aggregate: "(default)", verb: Ports::Persistence::VERB, adapter: name))
          adapter_class(name)
        rescue WiringError => e
          raise WiringError,
                "#{domain}'s world declares default_adapter #{name.inspect}, which is not a usable " \
                "persistence adapter: #{e.message}"
        end
      end
    end
  end
end
