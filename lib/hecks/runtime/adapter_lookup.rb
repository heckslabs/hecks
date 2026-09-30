require_relative "errors"

module Hecks
  module Runtime
    # Finds the one adapter this boot loaded for a port name.
    #
    # Shared by the port-operation interpreter (an aggregate asking out) and the query interpreter
    # (a query answered by a port), so both refuse the same way when nothing, or too much,
    # implements the port.
    module AdapterLookup
      module_function

      # @param registry [Runtime::Registry] the booted registry whose adapters are searched
      # @param port_name [String] the port's name as an adapter declares it
      # @param asked [String] what is being asked, worded into a refusal
      # @return [Object] a new instance of the port's only adapter
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements the port
      def call(registry, port_name, asked:) = adapter_class(registry, port_name, asked: asked).new

      # Finds the class of the one adapter this boot loaded for a port name, without building it,
      # so boot can check what the adapter answers before anything asks it.
      #
      # @param registry [Runtime::Registry] the booted registry whose adapters are searched
      # @param port_name [String] the port's name as an adapter declares it
      # @param asked [String] what is being asked, worded into a refusal
      # @return [Class] the port's only adapter
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements the port
      def adapter_class(registry, port_name, asked:)
        implementations = registry.adapters.values.select { |adapter| adapter.port == port_name }

        case implementations.size
        when 1 then Adapters.const_get(implementations.first.name)
        when 0 then raise WiringError, "no adapter implements the #{port_name} port — nothing can answer #{asked}"
        else raise WiringError,
                   "#{implementations.size} adapters implement the #{port_name} port " \
                   "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
