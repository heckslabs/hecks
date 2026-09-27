module Hecks
  module Runtime
    class Registry
      # **World defaults** — the `default_database` and `default_adapter` words a
      # `.world` can declare once for every chapter a boot loaded, resolved against
      # the registry's own worlds. Included into Registry; the callers are the
      # persistence binding policy (`default_adapter_for`), every reader of a bind's
      # world settings (`binding_settings`), and `verify!` (`verify_world_defaults!`).
      #
      # **Resolution order**, most specific first — nothing here ever overrides a
      # chapter's own explicit declaration:
      #
      #   1. the chapter's own `persisted_by(...) { database ... }` block, and the
      #      hecksagon bind (aggregate-specific, then domain-level) that names its adapter;
      #   2. the default declared by the chapter's own world;
      #   3. the default declared by the project's world — the world of the first
      #      chapter the boot loaded, the same convention `Loader#dispatcher_for` uses
      #      to find the domain a boot targets;
      #   4. today's behavior: no database setting, and the framework's in-memory
      #      adapter for a chapter with no hecksagon.
      #
      # A default is resolved when a bind's settings or binding are asked for, never
      # written into a chapter's world or hecksagon, so a chapter's own declarations
      # stay exactly what its files say and a hecksagon-less chapter still trips the
      # sibling-hecksagon gates the way it always did.
      module WorldDefaults
        # The settings a chapter's world gives one bind, with the project's default
        # database filled in where the chapter left it out.
        #
        # The default database only ever reaches a persistence bind whose adapter
        # declares a `database` field — a projection or an adapter without one is
        # untouched. A `database` the chapter's own settings name wins; every other
        # setting the chapter declared rides along unchanged.
        #
        # @param domain [String, Symbol] the domain whose world is asked
        # @param verb [String, Symbol] the bind's port verb, such as `"persisted_by"`
        # @param adapter [String, Symbol] the bind's adapter name
        # @return [Hash{Symbol => Object}] the chapter's own settings for the bind, plus
        #   `:database` from the default when one applies; `{}` when there is nothing
        def binding_settings(domain, verb, adapter)
          declared = world(domain)&.for_binding(verb, adapter) || {}
          database = default_database_for(domain)
          return declared unless database && default_database_applies?(verb, adapter)

          { adapter: adapter.to_s, database: database }.merge(declared)
        end

        # The persistence adapter a chapter's aggregates fall back to when their
        # hecksagon does not bind them.
        #
        # @param domain [String, Symbol] the domain to resolve the default for
        # @return [String, nil] the chapter's own world's `default_adapter`, else the
        #   project's; `nil` when neither declares one
        def default_adapter_for(domain) = world_default(domain, :default_adapter)

        # The database connection a chapter's database-taking persistence adapter uses
        # when its own settings name none.
        #
        # @param domain [String, Symbol] the domain to resolve the default for
        # @return [String, nil] the chapter's own world's `default_database`, else the
        #   project's; `nil` when neither declares one
        def default_database_for(domain) = world_default(domain, :default_database)

        # Refuses a `default_adapter` that no persistence adapter answers to.
        #
        # @return [Runtime::Registry] self
        # @raise [Runtime::WiringError] if a world's `default_adapter` names an unknown
        #   adapter, one that is not a persistence adapter, or one with no Ruby
        #   implementation
        def verify_world_defaults!
          @worlds.each_value do |declared|
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
        def project_world = world(@bluebooks.keys.first || @worlds.keys.first)

        def default_database_applies?(verb, adapter)
          verb.to_s == Ports::Persistence::VERB && @adapters[adapter.to_s]&.declares?(:database)
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
