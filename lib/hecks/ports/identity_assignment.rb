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

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can assign an identity"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
