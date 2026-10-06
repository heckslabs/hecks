require_relative "../runtime/registry"

module Hecks
  module Ports
    # Which value a creating command's identity field gets when its strategy names "port".
    # Delegates to the one adapter the domain wired.
    module IdentityAssignment
      NAME = "identity_assignment".freeze

      module_function

      # Asks the domain's adapter which value a creating command's identity field gets.
      #
      # Every argument other than `registry` is adapter-defined and forwarded untouched.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param agg_name [Object] adapter-defined; names the aggregate being assigned
      # @param field_name [Object] adapter-defined; names the identity field
      # @param args [Object] adapter-defined; the creating command's own arguments
      # @return [Object] adapter-defined value to assign as the identity
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      def assign(registry, agg_name:, field_name:, args:)
        adapter(registry).assign(registry, agg_name: agg_name, field_name: field_name, args: args)
      end

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
        return "no adapter implements the #{NAME} port — nothing can assign an identity" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end
