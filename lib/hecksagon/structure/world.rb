# Hecksagon::Structure::World
#
# Intermediate representation of runtime configuration + strategic
# descriptors. Holds per-extension config hashes populated by the World
# DSL (`heki do; ... end`, `ollama do; ... end`, ...) and top-level
# scalars (`purpose`, `vision`, `audience`) plus named `concern` blocks
# used by nursery/meta-domain .world files.
#
# Built by WorldBuilder, consumed by extensions and capabilities at
# boot time, and serialized to canonical JSON for the parity contract
# (spec/parity/world_parity_test.rb).
#
#   world = World.new(name: "Pizzas", configs: {
#     claude: { api_key: "sk-...", model: "claude-sonnet-4-5" }
#   })
#   world.config_for(:claude)  # => { api_key: "sk-...", model: "claude-sonnet-4-5" }
#
module Hecksagon
  module Structure
    class World
      attr_reader :name, :purpose, :vision, :audience, :concerns, :configs

      def initialize(name:, purpose: nil, vision: nil, audience: nil,
                     concerns: [], configs: {})
        @name     = name
        @purpose  = purpose
        @vision   = vision
        @audience = audience
        @concerns = concerns
        @configs  = configs
      end

      # Return the config hash for a specific extension.
      #
      # @param extension_name [Symbol, String] the extension name
      # @return [Hash] the config hash, or empty hash if not configured
      def config_for(extension_name)
        @configs[extension_name.to_sym] || {}
      end

      # JSON-safe hash representation — legacy shape (name + configs only).
      # Kept as-is so any external callers that rely on it keep working.
      #
      # @return [Hash] { name:, configs: { "claude" => {...}, ... } }
      def to_h
        { name: @name, configs: @configs.transform_keys(&:to_s) }
      end

      # Canonical JSON-safe shape matching the Rust dump-world output.
      # This is the parity contract (see spec/parity/world_parity_test.rb
      # and hecks_life/src/main.rs :: dump_world_json). Field order is not
      # load-bearing — the parity harness sorts keys before comparing.
      #
      # Values in `configs` are stringified so Ruby's Integer/Float/Symbol
      # values round-trip against the Rust parser's source-token preserving
      # output. Nil-valued concern descriptions stay nil (JSON null).
      def to_canonical_h
        concerns_h = @concerns.map do |c|
          { "name" => c[:name], "description" => c[:description] }
        end
        configs_h = @configs.each_with_object({}) do |(ext, values), acc|
          acc[ext.to_s] = values.each_with_object({}) do |(k, v), inner|
            inner[k.to_s] = canonical_value(v)
          end
        end
        {
          "name"     => @name,
          "purpose"  => @purpose,
          "vision"   => @vision,
          "audience" => @audience,
          "concerns" => concerns_h,
          "configs"  => configs_h,
        }
      end

      private

      # Render a config value as the source-text token the Rust parser
      # captures. Strings stay as-is (quotes already stripped at parse
      # time); numerics/booleans become their textual form; arrays keep
      # the Ruby inspect-like shape Rust preserves verbatim.
      def canonical_value(v)
        case v
        when String        then v
        when Numeric, TrueClass, FalseClass then v.to_s
        when Symbol        then v.to_s
        when nil           then ""
        when Array         then v.map { |e| e.is_a?(String) ? "\"#{e}\"" : e.to_s }.join(", ")
        else v.to_s
        end
      end
    end
  end
end
