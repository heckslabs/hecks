require_relative "../runtime/errors"

module Hecks
  module Ports
    # The `dispatch` port: who runs a domain's writes. Unbound, the boot's own `Dispatcher` does;
    # a world's `dispatched_by("<Adapter>")` hands the job to that adapter, which answers
    # `dispatcher(registry, settings)` with something of `Dispatcher`'s public shape.
    module Dispatch
      VERB = "dispatched_by".freeze

      module_function

      # Builds the dispatcher the world's `dispatched_by` binding names.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param settings [Hash{Symbol => Object}] the binding: `:adapter` plus its declared settings
      # @return [Object] the bound adapter's dispatcher
      # @raise [Runtime::WiringError] if the adapter is unknown or cannot build a dispatcher
      def dispatcher(registry, settings)
        adapter = registry.adapter_class(settings[:adapter])
        return adapter.dispatcher(registry, settings) if adapter.respond_to?(:dispatcher)

        raise Runtime::WiringError,
              "#{settings[:adapter]} cannot dispatch: it answers no `dispatcher` for `#{VERB}`"
      end
    end
  end
end
