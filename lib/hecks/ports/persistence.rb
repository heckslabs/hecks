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
require_relative "persistence/state_codec"

module Hecks
  module Ports
    # Reopened once `BindingPolicy`/`RepositoryFactory` (required above) are
    # loaded, to add the persistence port's actual call surface: resolving
    # which adapter authoritatively binds an aggregate and building the
    # repository that reads/writes it.
    module Persistence
      module_function

      # The public persistence port owns only authoritative aggregate heads.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the binding against
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate [Object] the aggregate to build a repository for
      # @return [Object] a repository backed by the aggregate's authoritative adapter
      def repository(registry, domain, aggregate)
        authoritative = BindingPolicy.resolve(registry, domain, aggregate)
        RepositoryFactory.build(registry, domain, aggregate, authoritative)
      end

      # @param registry [Runtime::Registry] the booted registry to resolve the binding against
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate [Object] the aggregate to resolve a binding for
      # @return [Array(Object, Array)] the authoritative bind, and an empty array (there is
      #   never more than one authoritative bind)
      def binds_for(registry, domain, aggregate)
        [BindingPolicy.resolve(registry, domain, aggregate), []]
      end

      # @param registry [Runtime::Registry] the booted registry to resolve the binding against
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate [Object] the aggregate to resolve a binding for
      # @return [Object] the aggregate's authoritative bind
      def bind_for(registry, domain, aggregate)
        binds_for(registry, domain, aggregate).first
      end
    end
  end
end
