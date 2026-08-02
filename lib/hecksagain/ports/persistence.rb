module Hecksagain
  module Ports
    module Persistence
      NAME = "persistence"
      VERB = "persisted_by"
      DEFAULT_ADAPTER = "Memory"
    end
  end
end

require_relative "persistence/binding_policy"
require_relative "persistence/lineage"
require_relative "persistence/era_tamper"
require_relative "persistence/repository_factory"
require_relative "persistence/append_only"

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
