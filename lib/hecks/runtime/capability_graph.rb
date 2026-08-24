module Hecks
  module Runtime
    # WHICH PORTS A BOOT CAN ACTUALLY FULFILL, read off the registry it already
    # holds. `registry.ports` names every port a domain declared a dependency
    # on ; `registry.adapters` names every adapter wired to implement one — the
    # same `adapter.port == port.name` match `Ports::Extraction` and
    # `Ports::IdentityGeneration` already make for themselves, one at a time,
    # each time they resolve. This is that same question asked once, for
    # every port at once, so a gap in the wiring is something a caller can ASK
    # about rather than something a live dispatch discovers by refusing.
    #
    # `cycles` answers `[]`, always, and honestly: nothing in this port model
    # lets one port depend on another — a port names a verb and a signal, an
    # adapter names the port it implements, and neither can point at a third
    # port. There is no edge for a cycle to be made of.
    class CapabilityGraph
      def initialize(registry)
        @registry = registry
      end

      # { port name => [adapter name, ...] }, for every port the registry
      # declares — including the ports nothing implements, so a caller can
      # tell "declared, unfulfilled" from "never declared at all".
      def fulfillments
        @fulfillments ||= @registry.ports.each_key.to_h { |name| [name, adapters_for(name)] }
      end

      # The ports with zero adapters bound — the gap `Runtime::WiringError`
      # would otherwise only surface at the moment something tries to dispatch
      # through one.
      def unfulfilled
        fulfillments.select { |_, adapters| adapters.empty? }.keys
      end

      def cycles = []

      private

      def adapters_for(port_name)
        @registry.adapters.values.select { |adapter| adapter.port == port_name }.map(&:name)
      end
    end
  end
end
