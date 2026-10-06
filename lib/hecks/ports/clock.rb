require_relative "../runtime/registry"

module Hecks
  module Ports
    # What time it is, as one registry-wide adapter answers it.
    # Predicates cannot read the clock (replays must be deterministic), so a command that declares
    # `needs :now` has the runtime read it once, before any given runs, into the command's own
    # `now` argument (ADR 0081). The recorded argument is what a replay sees.
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
        return registry.adapter_class(implementations.first.name) if implementations.size == 1

        raise Runtime::WiringError, wiring_refusal(implementations)
      end

      # Words the refusal for a port that resolves to no adapter or to several.
      #
      # @param implementations [Array] the adapters bound to this port
      # @return [String] the error message
      def wiring_refusal(implementations)
        return "no adapter implements the #{NAME} port — nothing can say what time it is" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end
