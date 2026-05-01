# Hecks::Capabilities::DSL
#
# DSL for declaring capabilities. The config block declares the
# schema AND becomes the reader — world config is merged over
# defaults and passed to on_apply as a resolved config object.
#
#   Hecks.capability :websocket do
#     description "Bidirectional WebSocket"
#     config do
#       port 4568, desc: "Listen port"
#     end
#     on_apply do |runtime, config|
#       # config.port → world value or default 4568
#     end
#   end
#
module Hecks
  module Capabilities
    # Hecks::Capabilities::DSL
    #
    # Declares capabilities with auto-resolved config from world.
    #
    class DSL
      def initialize(name)
        @name = name.to_sym
        @description = ""
        @direction = nil
        @config_schema = {}
        @apply_block = nil
      end

      def description(text)
        @description = text
      end

      # Declare port direction: :driving (outside calls in) or :driven (domain calls out)
      def direction(dir)
        @direction = dir.to_sym
      end

      def config(&block)
        builder = ConfigBuilder.new
        builder.instance_eval(&block)
        @config_schema = builder.schema
      end

      def on_apply(&block)
        @apply_block = block
      end

      def register!
        schema = @config_schema
        name = @name
        apply_block = @apply_block

        Hecks.register_capability(name) do |runtime|
          apply_block&.call(runtime)
        end

        dir = @direction
        Hecks.describe_capability(name, description: @description, config: schema)
        Hecks.capability_meta[name][:direction] = dir if dir
      end
    end

    # Captures config keys: port 4568, desc: "..."
    class ConfigBuilder
      attr_reader :schema

      def initialize
        @schema = {}
      end

      def method_missing(key, default = nil, desc: nil)
        @schema[key.to_sym] = { default: default, desc: desc || key.to_s }
      end

      def respond_to_missing?(_, _ = false) = true
    end
  end

  def self.capability(name, &block)
    dsl = Capabilities::DSL.new(name)
    dsl.instance_eval(&block)
    dsl.register!
  end
end
