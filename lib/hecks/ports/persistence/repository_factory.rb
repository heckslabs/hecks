require_relative "append_only"
require_relative "codec_boundary"

module Hecks
  module Ports
    module Persistence
      # Turns a declared adapter binding into a concrete repository, guarding every
      # adapter it builds (`CodecBoundary.guard!`) before `recover!` or anything else touches it.
      module RepositoryFactory
        module_function

        # Instantiates the adapter a bind names, guards it, and wraps it as a repository.
        def build(registry, domain, aggregate, bind, recover: true, settings_verb: VERB)
          registry.check_verb(bind)
          settings = registry.binding_settings(domain, settings_verb, bind.adapter)
                             .reject { |key, _| key.to_sym == :role }
          registry.check_settings(bind, settings)
          # domain, resolved era and superseding era ride along outside the declared
          # settings: a lineage adapter needs them to journal per domain, per-era.
          adapter = registry.adapter_class(bind.adapter)
                            .new(aggregate: aggregate,
                                 settings:  settings.merge(domain: domain.to_s, era: registry.resolved_eras[domain.to_s],
                                                           superseded_by: registry.superseded_eras[domain.to_s]),
                                 root:      registry.root)
          repository = AppendOnly.new(CodecBoundary.guard!(adapter))
          # `:atomic_append` (PostgresEra) means `append` already committed the
          # projected state in the same transaction as the journal row, so a
          # boot-time replay through `project` has nothing left to fix up.
          recover && !repository.capabilities.include?(:atomic_append) ? repository.recover! : repository
        end
      end
    end
  end
end
