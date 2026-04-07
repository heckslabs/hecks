  # HecksTenancy::TenantScopedRepository
  #
  # Repository proxy that isolates data per tenant. Wraps a repository class
  # and maintains separate instances keyed by tenant ID (from +Hecks.tenant+).
  # All standard repository operations (find, save, delete, all, count, clear,
  # query) delegate to the current tenant's dedicated repository instance.
  #
  # When +Hecks.tenant+ is nil, operations fall back to a "__default__" tenant.
  # Each tenant gets a lazily-instantiated repository of the wrapped class.
  #
  #   proxy = TenantScopedRepository.new(PizzaMemoryRepository)
  #   Hecks.tenant = "acme"
  #   proxy.save(pizza)     # stored under acme
  #   Hecks.tenant = "beta"
  #   proxy.all             # => [] (beta has nothing)
  #
module HecksTenancy
  # HecksTenancy::TenantScopedRepository
  #
  # Repository proxy that maintains separate instances per tenant, isolating all data operations by tenant ID.
  #
  class TenantScopedRepository
    # Create a new tenant-scoped proxy wrapping the given repository class.
    #
    # The repository class is instantiated lazily for each tenant on first
    # access. Instances are cached in an internal hash keyed by tenant ID.
    #
    # @param repo_class [Class] the repository class to instantiate per
    #   tenant; must respond to +.new+ with no arguments and provide
    #   standard repository methods (find, save, delete, all, count, clear, query)
    # @return [TenantScopedRepository] a new proxy instance
    def initialize(repo_class)
      @repo_class = repo_class
      @stores = {}
    end

    # Return the repository instance for the current tenant.
    #
    # Reads +Hecks.tenant+ to determine the current tenant ID. Falls back
    # to "__default__" if no tenant is set. Lazily creates a new repository
    # instance for each tenant on first access.
    #
    # @return [Object] the repository instance for the current tenant
    def for_tenant
      tenant = Hecks.tenant || "__default__"
      @stores[tenant] ||= @repo_class.new
    end

    # Find an aggregate by ID within the current tenant's store.
    #
    # @param id [String] the aggregate ID to look up
    # @return [Object, nil] the found aggregate, or nil if not found
    def find(id)
      for_tenant.find(id)
    end

    # Persist an aggregate in the current tenant's store.
    #
    # @param aggregate [Object] the aggregate instance to save
    # @return [Object] the saved aggregate (may have generated ID)
    def save(aggregate)
      for_tenant.save(aggregate)
    end

    # Delete an aggregate by ID from the current tenant's store.
    #
    # @param id [String] the aggregate ID to delete
    # @return [void]
    def delete(id)
      for_tenant.delete(id)
    end

    # Return all aggregates in the current tenant's store.
    #
    # @return [Array<Object>] all aggregate instances for the current tenant
    def all
      for_tenant.all
    end

    # Return the count of aggregates in the current tenant's store.
    #
    # @return [Integer] the number of stored aggregates for the current tenant
    def count
      for_tenant.count
    end

    # Remove all aggregates from the current tenant's store.
    #
    # @return [void]
    def clear
      for_tenant.clear
    end

    # Query the current tenant's store with the given conditions.
    #
    # @param kwargs [Hash] keyword arguments passed through to the
    #   underlying repository's +query+ method
    # @return [Array<Object>] matching aggregate instances
    def query(**kwargs)
      for_tenant.query(**kwargs)
    end
  end
end
