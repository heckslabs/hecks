require_relative "errors"

module Hecks
  module Runtime
    # Finds the one adapter this boot loaded for a port name.
    #
    # Shared by the port-operation interpreter (an aggregate asking out) and the query interpreter
    # (a query answered by a port), so both refuse the same way when nothing, or too much,
    # implements the port.
    module AdapterLookup
      @stand_in = nil

      module_function

      # Answers every port with a stand-in instead of its adapter while the block runs, for a
      # caller that must not reach what the adapters reach (the fuzzer replays a domain whose
      # adapters run shells and write files). Boot still checks the real adapters' classes; only
      # what `call` hands out changes.
      #
      # @param stand_in [#call] answers `(port_name, asked)` with the object to ask instead
      # @yield the work to run with the stand-in in place
      # @return [Object] what the block answers
      def standing_in(stand_in)
        previous = @stand_in
        @stand_in = stand_in
        yield
      ensure
        @stand_in = previous
      end

      # @param registry [Runtime::Registry] the booted registry whose adapters are searched
      # @param port_name [String] the port's name as an adapter declares it
      # @param asked [String] what is being asked, worded into a refusal
      # @return [Object] a new instance of the port's only adapter, or the stand-in for it
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements the port
      def call(registry, port_name, asked:)
        adapter_class(registry, port_name, asked: asked)
        return @stand_in.call(port_name, asked) if @stand_in

        adapter_class(registry, port_name, asked: asked).new
      end

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
