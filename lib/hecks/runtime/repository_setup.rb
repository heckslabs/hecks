module Hecks
  class Runtime
      # Hecks::Runtime::RepositorySetup
      #
      # Mixin that creates a memory-adapter repository for each aggregate,
      # unless an explicit adapter override was supplied in the Runtime
      # config block.
      #
      #   class Runtime
      #     include RepositorySetup
      #   end
      #
      module RepositorySetup
        private

        # Creates and stores a repository instance for each aggregate in the domain.
        #
        # For each aggregate, checks +@adapter_overrides+ (a Hash keyed by aggregate
        # name) for a user-supplied adapter. If an override exists, uses it directly.
        # Otherwise, instantiates the default memory repository by resolving the
        # constant +Adapters::<AggregateName>MemoryRepository+ under the domain module.
        #
        # Populates +@repositories+ (a Hash keyed by aggregate name) which is later
        # used by PortSetup to bind persistence methods onto aggregate classes.
        #
        # @return [void]
        def setup_repositories
          @domain.aggregates.each do |agg|
            if @adapter_overrides.key?(agg.name)
              @repositories[agg.name] = @adapter_overrides[agg.name]
            else
              adapter_class = @mod::Adapters.const_get("#{agg.name}MemoryRepository")
              @repositories[agg.name] = adapter_class.new
            end
          end
        end
      end
  end
end
