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
require "ostruct"

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
        @config_schema = {}
        @apply_block = nil
      end

      def description(text)
        @description = text
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

        Hecks.describe_capability(name, description: @description, config: schema)
      end

      def self.resolve_config(name, schema)
        world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
        world_values = world ? world.config_for(name) : {}

        merged = {}
        schema.each do |key, opts|
          merged[key] = world_values.key?(key) ? world_values[key] : opts[:default]
        end

        # Also include any world keys not in schema
        world_values.each { |k, v| merged[k] = v unless merged.key?(k) }

        OpenStruct.new(merged)
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
