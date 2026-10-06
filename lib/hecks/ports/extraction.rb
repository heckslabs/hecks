require_relative "../runtime/registry"

module Hecks
  module Ports
    # Resolves the adapter that recovers a predicate's own source (`canonical`).
    # Reads `Hecks.current_registry`, since extraction only happens while a bluebook loads.
    module Extraction
      NAME = "extraction".freeze

      module_function

      # Recovers a block's body as canonical source text, so a rule is carried as text.
      #
      # @param block [Proc] a block written in a bluebook file, such as a `given` predicate
      #   or an `identified_by` path
      # @return [String, nil] the block body's source, normalised by
      #   `Bluebook::Expression::CanonicalForm`; nil if the block's file cannot be read, no
      #   block starts on its line, or the block has an empty body
      # @raise [Runtime::WiringError] if called outside a boot, or this port does not resolve
      #   to exactly one adapter
      def canonical(block) = adapter.canonical(block)

      # Finds the single adapter bound to this port in the registry currently booting.
      #
      # @raise [Runtime::WiringError] if called outside a boot, or none, or more than one,
      #   implements this port
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
                "(#{implementations.map(&:name).sort.join(", ")}) — the runtime " \
                "will not choose for you"
        end
      end
    end
  end
end
