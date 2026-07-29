module Hecksagain
  module Ports
    module Persistence
      # Turns a declared adapter binding plus its world configuration into a
      # concrete repository. Selection policy stays out of adapter creation.
      module RepositoryFactory
        module_function

        def build(registry, domain, aggregate, bind, recover: true, settings_verb: VERB)
          registry.check_verb(bind)
          settings = (registry.world(domain)&.for_binding(settings_verb, bind.adapter) || {})
                     .reject { |key, _| key.to_sym == :role }
          registry.check_settings(bind, settings)
          adapter = registry.adapter_class(bind.adapter).new(aggregate: aggregate, settings: settings, root: registry.root)
          repository = AppendOnly.new(adapter)
          recover ? repository.recover! : repository
        end
      end
    end
  end
end
