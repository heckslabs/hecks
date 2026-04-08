# Hecksagon::Structure::World
#
# Intermediate representation of runtime configuration. Holds per-extension
# config hashes populated by the World DSL. Built by WorldBuilder, consumed
# by extensions and capabilities at boot time.
#
#   world = World.new(name: "Pizzas", configs: {
#     claude: { api_key: "sk-...", model: "claude-sonnet-4-5" }
#   })
#   world.config_for(:claude)  # => { api_key: "sk-...", model: "claude-sonnet-4-5" }
#
module Hecksagon
  module Structure
    class World
      attr_reader :name, :configs

      def initialize(name:, configs: {})
        @name = name
        @configs = configs
      end

      # Return the config hash for a specific extension.
      #
      # @param extension_name [Symbol, String] the extension name
      # @return [Hash] the config hash, or empty hash if not configured
      def config_for(extension_name)
        @configs[extension_name.to_sym] || {}
      end

      # JSON-safe hash representation.
      #
      # @return [Hash] { name:, configs: { "claude" => {...}, ... } }
      def to_h
        { name: @name, configs: @configs.transform_keys(&:to_s) }
      end
    end
  end
end
