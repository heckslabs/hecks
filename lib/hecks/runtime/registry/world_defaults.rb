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

        # The defaults an adapter's `.adapter` declares for its fields, with each `{name}` or
        # `{storage_name}` in a string filled from `aggregate`. A world's own setting always wins.
        #
        # @param adapter [String, Symbol] the adapter's name
        # @param aggregate [Bluebook::Aggregate] the aggregate the adapter is built for
        # @return [Hash{Symbol => Object}] the defaults, empty when the adapter declares none
        def adapter_defaults(adapter, aggregate)
          declared = @declared.adapters[adapter.to_s]&.declared_defaults || {}
          declared.transform_values { |value| fill_placeholders(value, aggregate) }
        end

        # `settings` laid over the adapter's declared defaults. A field a world gives as `:default`
        # asks for the declared default, so it is left out and the default shows through.
        #
        # @param adapter [String, Symbol] the adapter's name
        # @param aggregate [Bluebook::Aggregate] the aggregate the adapter is built for
        # @param settings [Hash{Symbol => Object}] the settings the world gave
        # @return [Hash{Symbol => Object}] the defaults, overridden by the settings given
        def with_adapter_defaults(adapter, aggregate, settings)
          adapter_defaults(adapter, aggregate).merge(settings.reject { |_, value| value == :default })
        end

        private

        # A string default with its placeholders filled from the aggregate; any other value as is.
        def fill_placeholders(value, aggregate)
          return value unless value.is_a?(String)

          value.gsub(/\{(name|storage_name)\}/) { aggregate.public_send(Regexp.last_match(1)) }
        end

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
