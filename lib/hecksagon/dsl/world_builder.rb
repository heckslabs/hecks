# Hecksagon::DSL::WorldBuilder
#
# DSL builder for the World file — runtime configuration for extensions
# and adapters, plus strategic descriptors for nursery/meta-domain worlds.
#
# Each extension name becomes a method that takes a block, and the block's
# methods become key-value config pairs. Top-level scalars (purpose,
# vision, audience) capture strategic intent. `concern "Name"` blocks add
# named concerns with a `description`.
#
# The World file sits alongside the Bluebook (domain) and Hecksagon (wiring)
# files, providing concrete infrastructure credentials, options, AND the
# strategic framing a nursery/meta domain needs.
#
#   # Family A — runtime/extension config
#   builder = WorldBuilder.new("Pizzas")
#   builder.instance_eval do
#     claude do
#       api_key ENV["ANTHROPIC_API_KEY"]
#       model "claude-sonnet-4-5"
#     end
#   end
#   world = builder.build
#   world.config_for(:claude) # => { api_key: "sk-...", model: "claude-sonnet-4-5" }
#
#   # Family B — strategic descriptors
#   builder = WorldBuilder.new("DomainConception")
#   builder.instance_eval do
#     purpose "..."
#     vision  "..."
#     concern "CompletenessAtBirth" do
#       description "..."
#     end
#   end
#   world = builder.build
#   world.purpose   # => "..."
#   world.concerns  # => [{ name: "Completeness...", description: "..." }]
#
module Hecksagon
  module DSL
    class WorldBuilder
      # Scalar top-level keywords — purpose / vision / audience store a
      # single string each. Anything else with a block is an extension
      # config.
      SCALAR_KEYS = %i[purpose vision audience].freeze

      def initialize(name = nil)
        @name = name
        @configs = {}
        @concerns = []
        @scalars = {}
      end

      # Top-level `purpose "..."` — strategic intent.
      def purpose(value) = @scalars[:purpose] = value
      # Top-level `vision "..."` — longer-horizon direction.
      def vision(value)  = @scalars[:vision]  = value
      # Top-level `audience "..."` — who the world is for.
      def audience(value) = @scalars[:audience] = value

      # `concern "Name" do; description "..." end` — named concern block.
      def concern(name, &block)
        builder = ConcernBuilder.new(name)
        builder.instance_eval(&block) if block
        @concerns << builder.to_h
      end

      def method_missing(ext_name, *args, &block)
        if block
          config_builder = ExtensionConfigBuilder.new
          config_builder.instance_eval(&block)
          @configs[ext_name.to_sym] = config_builder.to_h
        else
          super
        end
      end

      def respond_to_missing?(name, _ = false)
        true
      end

      # Build and return the World IR object.
      #
      # @return [Hecksagon::Structure::World]
      def build
        Structure::World.new(
          name:     @name,
          purpose:  @scalars[:purpose],
          vision:   @scalars[:vision],
          audience: @scalars[:audience],
          concerns: @concerns,
          configs:  @configs,
        )
      end
    end

    # Collects key-value pairs from a World extension config block.
    #
    #   claude do
    #     api_key ENV["ANTHROPIC_API_KEY"]
    #     model "claude-sonnet-4-5"
    #   end
    #
    class ExtensionConfigBuilder
      def initialize
        @values = {}
      end

      def method_missing(key, *values)
        @values[key.to_sym] = values.size == 1 ? values.first : values
        @values[key.to_sym]
      end

      def respond_to_missing?(_, _ = false) = true

      def to_h
        @values
      end
    end

    # `concern "Name" do; description "..." end` — collects a concern's
    # attributes into a plain hash. Only `description` is recognized
    # today; more attributes can be added without changing the shape
    # of the World IR.
    class ConcernBuilder
      def initialize(name)
        @name = name
        @description = nil
      end

      def description(text) = @description = text

      def to_h
        { name: @name, description: @description }
      end
    end
  end
end
