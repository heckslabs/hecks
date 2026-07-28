module Hecksagain
  module Ports
    module Persistence
      NAME = "persistence"
      VERB = "persisted_by"

      DEFAULT_ADAPTER = "Memory"

      module_function

      def repository(registry, domain, aggregate)
        bind = bind_for(registry, domain, aggregate)

        registry.check_verb(bind)

        settings = registry.world(domain)&.for_verb(bind.verb) || {}
        registry.check_settings(bind, settings)

        registry.adapter_class(bind.adapter)
                .new(aggregate: aggregate, settings: settings, root: registry.root)
      end

      def bind_for(registry, domain, aggregate)
        hexagon = registry.hecksagon(domain)
        return default_bind(aggregate) unless hexagon

        hexagon.bind_for(aggregate.name, VERB) || raise(
          Runtime::WiringError,
          "#{domain}::#{aggregate.name} has no #{VERB} bind. #{domain} declares a " \
          "hecksagon, so its wiring is being decided explicitly and an aggregate " \
          "left out is a forgotten decision. Bind it, or say " \
          "#{aggregate.name}.#{VERB}(#{DEFAULT_ADAPTER.inspect}) to keep it in " \
          "memory on purpose."
        )
      end

      def default_bind(aggregate)
        Bluebook::IR::Bind.new(
          aggregate: aggregate.name,
          verb:      VERB,
          adapter:   DEFAULT_ADAPTER
        )
      end


    end
  end
end
