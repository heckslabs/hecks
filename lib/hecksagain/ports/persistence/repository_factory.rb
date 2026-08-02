require_relative "append_only"

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
          # The domain and the resolved era ride along after the
          # declared-settings check: a lineage adapter journals per
          # DOMAIN and writes into its own ERA's partition — neither of
          # which a world's settings carry.
          adapter = registry.adapter_class(bind.adapter)
                            .new(aggregate: aggregate,
                                 settings: settings.merge(domain: domain.to_s, era: registry.resolved_eras[domain.to_s]),
                                 root: registry.root)
          repository = AppendOnly.new(adapter)
          recover ? repository.recover! : repository
        end
      end
    end
  end
end
