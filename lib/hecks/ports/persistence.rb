module Hecks
  module Ports
    module Persistence
      NAME = "persistence".freeze
      VERB = "persisted_by".freeze
      DEFAULT_ADAPTER = "Memory".freeze
    end
  end
end

require_relative "persistence/binding_policy"
require_relative "persistence/plugin"
require_relative "persistence/repository_factory"
require_relative "persistence/append_only"
require_relative "persistence/execution"
require_relative "persistence/remote_runtime"
require_relative "persistence/null_saga_store"

module Hecks
  module Ports
    # Reopened once `BindingPolicy`/`RepositoryFactory` (required above) are
    # loaded, to add the persistence port's actual call surface: resolving
    # which adapter authoritatively binds an aggregate and building the
    # repository that reads/writes it.
    module Persistence
      module_function

      # The public persistence port owns only authoritative aggregate heads.
      def repository(registry, domain, aggregate)
        authoritative = BindingPolicy.resolve(registry, domain, aggregate)
        RepositoryFactory.build(registry, domain, aggregate, authoritative)
      end

      def binds_for(registry, domain, aggregate)
        [BindingPolicy.resolve(registry, domain, aggregate), []]
      end

      def bind_for(registry, domain, aggregate)
        binds_for(registry, domain, aggregate).first
      end
    end
  end
end
