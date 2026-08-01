module Hecksagain
  module Ports
    module Persistence
      NAME = "persistence"
      VERB = "persisted_by"
      DEFAULT_ADAPTER = "Memory"
    end
  end
end

require_relative "binding_policy"
require_relative "lineage"
require_relative "era_tamper"
require_relative "era_store"
require_relative "repository_factory"
require_relative "append_only"

module Hecksagain
  module Ports
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
