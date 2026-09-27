require_relative "../runtime/registry"

module Hecks
  module Ports
    # What time it is, as one registry-wide adapter answers it.
    # Predicates cannot read the clock (replays must be deterministic), so the door fills `now`.
    module Clock
      NAME = "clock".freeze

      module_function

      # Reads the current time from the bound clock adapter.
      #
      # Integer seconds, because the expression sublanguage can add and compare but a Time
      # object supports neither.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [Integer] the current time, in Unix epoch seconds
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      def now(registry) = adapter(registry).now

      # Finds the single adapter bound to this port.
      #
      # @raise [Runtime::WiringError] if none, or more than one, implements this port
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can say what time it is"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
