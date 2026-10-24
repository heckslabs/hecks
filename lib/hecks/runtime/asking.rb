module Hecks
  module Runtime
    # The registry whose port operation is asking an adapter, bound on this thread for the
    # length of the ask, so an adapter that answers by dispatching reaches the same boot
    # (ADR 0121). An adapter is built with a bare `.new` and is handed no registry otherwise.
    module Asking
      module_function

      # @return [Runtime::Registry, nil] the asking registry, or nil outside an ask
      def registry = Thread.current[:hecks_asking_registry]

      # Binds `registry` as the asking registry for the block, restoring the previous one.
      #
      # @param registry [Runtime::Registry] the registry whose port operation asks
      # @yield the ask
      # @return [Object] the block's result
      def with(registry)
        previous = Thread.current[:hecks_asking_registry]
        Thread.current[:hecks_asking_registry] = registry
        yield
      ensure
        Thread.current[:hecks_asking_registry] = previous
      end
    end
  end
end
