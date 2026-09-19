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

      # Builds the repository that reads and writes one aggregate's authoritative store.
      #
      # The public persistence port owns only authoritative aggregate heads. The repository
      # comes back already recovered: every journal entry has been re-projected.
      #
      # @param registry [Runtime::Registry] the booted registry holding the domain's
      #   hecksagon, world and adapters
      # @param domain [String, Symbol] name of the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate to persist
      # @return [Persistence::AppendOnly] repository over the aggregate's authoritative
      #   adapter, or over a `Memory` adapter when the domain declares no hecksagon
      # @raise [Runtime::WiringError] if the aggregate has no authoritative bind, more than
      #   one, or a bind with a role this port does not support; or if the bound adapter is
      #   unknown, answers a different verb, is given a setting it does not declare, has no
      #   Ruby implementation, or lacks a method its port's `answers` list or the
      #   append-only contract (`append`, `project`, `entries`) requires
      def repository(registry, domain, aggregate)
        authoritative = BindingPolicy.resolve(registry, domain, aggregate)
        RepositoryFactory.build(registry, domain, aggregate, authoritative)
      end

      # Resolves an aggregate's authoritative bind, paired with an always-empty Array.
      #
      # @param registry [Runtime::Registry] the booted registry holding the domain's hecksagon
      # @param domain [String, Symbol] name of the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate whose binding is wanted
      # @return [Array(Bluebook::Bind, Array)] the authoritative `persisted_by` bind (the
      #   default `Memory` bind when the domain declares no hecksagon), then an Array that
      #   is always `[]`
      # @raise [Runtime::WiringError] if the aggregate has no authoritative bind, more than
      #   one, or a bind with a role this port does not support
      def binds_for(registry, domain, aggregate)
        [BindingPolicy.resolve(registry, domain, aggregate), []]
      end

      # Resolves the one bind naming an aggregate's authoritative store.
      #
      # @param registry [Runtime::Registry] the booted registry holding the domain's hecksagon
      # @param domain [String, Symbol] name of the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate whose binding is wanted
      # @return [Bluebook::Bind] the authoritative `persisted_by` bind, or the default
      #   `Memory` bind when the domain declares no hecksagon
      # @raise [Runtime::WiringError] if the aggregate has no authoritative bind, more than
      #   one, or a bind with a role this port does not support
      def bind_for(registry, domain, aggregate)
        binds_for(registry, domain, aggregate).first
      end
    end
  end
end
