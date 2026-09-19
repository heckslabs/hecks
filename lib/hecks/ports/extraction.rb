require_relative "../runtime/registry"

module Hecks
  module Ports
    # The `extraction` port: resolves whichever adapter can recover a
    # predicate's own source (`canonical`). Reads `Hecks.current_registry`
    # directly rather than taking a registry argument, since extraction only
    # ever happens while a bluebook is loading, never after boot.
    module Extraction
      NAME = "extraction".freeze

      module_function

      # @param block [Proc] a predicate block, as written in the bluebook
      # @return [String] the block's own source text
      def canonical(block) = adapter.canonical(block)

      # Finds the single adapter bound to this port.
      #
      # @return [Class] the adapter class implementing this port
      # @raise [Runtime::WiringError] if resolved outside a boot, or if zero or more than one
      #   adapter implements it
      def adapter
        registry = Hecks.current_registry
        unless registry
          raise Runtime::WiringError,
                "extraction resolved outside a boot — a predicate can only be " \
                "read while a bluebook is loading"
        end

        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can recover a " \
                "predicate's source"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime " \
                "will not choose for you"
        end
      end
    end
  end
end
