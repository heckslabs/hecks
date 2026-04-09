module Hecksagon
  module DSL

    # Hecksagon::DSL::ContextMapBuilder
    #
    # DSL builder for context map declarations within a hecksagon. Collects
    # upstream/downstream and shared-kernel relationships between bounded
    # contexts.
    #
    #   builder = ContextMapBuilder.new
    #   builder.upstream "Pizzas", downstream: "Billing", relationship: :anti_corruption
    #   builder.shared_kernel "Pizzas", "Inventory", shared: ["ToppingName"]
    #   builder.build  # => [{ type: :upstream_downstream, ... }, ...]
    #
    class ContextMapBuilder
      def initialize
        @relationships = []
      end

      # Declare an upstream/downstream relationship between two contexts.
      #
      # @param source [String] the upstream context name
      # @param downstream [String] the downstream context name
      # @param relationship [Symbol] the integration pattern (:conformist, :anti_corruption, etc.)
      # @return [void]
      def upstream(source, downstream:, relationship: :conformist)
        @relationships << {
          type: :upstream_downstream,
          source: source,
          target: downstream,
          relationship: relationship
        }
      end

      # Declare a shared-kernel relationship between two contexts.
      #
      # @param context_a [String] first context name
      # @param context_b [String] second context name
      # @param shared [Array<String>] list of shared concept names
      # @return [void]
      def shared_kernel(context_a, context_b, shared: [])
        @relationships << {
          type: :shared_kernel,
          contexts: [context_a, context_b],
          shared: shared
        }
      end

      # Build and return the list of context map relationships.
      #
      # @return [Array<Hash>]
      def build
        @relationships
      end
    end
  end
end
