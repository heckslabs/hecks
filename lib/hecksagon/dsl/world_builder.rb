# Hecksagon::DSL::WorldBuilder
#
# DSL builder for the World file — runtime configuration for extensions
# and adapters. Each extension name becomes a method that takes a block,
# and the block's methods become key-value config pairs.
#
# The World file sits alongside the Bluebook (domain) and Hecksagon (wiring)
# files, providing concrete infrastructure credentials and options.
#
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
module Hecksagon
  module DSL
    class WorldBuilder
      def initialize(name = nil)
        @name = name
        @configs = {}
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
        Structure::World.new(name: @name, configs: @configs)
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
  end
end
