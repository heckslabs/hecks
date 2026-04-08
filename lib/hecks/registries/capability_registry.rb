# Hecks::CapabilityRegistryMethods
#
# Registry for domain capabilities. Capabilities enrich the domain IR by
# generating constructs (commands, repository bindings) at runtime.
# Each capability can declare its config schema via describe_capability,
# which enables auto-generation of world.hec config blocks.
#
#   Hecks.register_capability(:crud) { |runtime| CrudCapability.apply(runtime) }
#   Hecks.describe_capability(:websocket, config: { port: { default: 4568, desc: "WebSocket port" } })
#   Hecks.capability_registry  # => { crud: #<Proc> }
#   Hecks.capability_config(:websocket) # => { port: { default: 4568, desc: "..." } }
#
module Hecks
  # Hecks::CapabilityRegistryMethods
  #
  # Registry for domain capabilities with optional config metadata.
  #
  module CapabilityRegistryMethods
    def capability_registry
      @capability_registry ||= Registry.new
    end

    def capability_meta
      @capability_meta ||= Registry.new
    end

    def register_capability(name, &hook)
      capability_registry.register(name, hook)
    end

    # Declare a capability's config schema. Used to auto-generate
    # commented world.hec blocks when a capability is added.
    #
    # @param name [Symbol] capability name
    # @param description [String] what this capability does
    # @param config [Hash] config keys with :default and :desc
    def describe_capability(name, description: "", config: {})
      capability_meta.register(name, {
        description: description,
        config: config
      })
    end

    # Return the config schema for a capability.
    #
    # @param name [Symbol] capability name
    # @return [Hash] config schema or empty hash
    def capability_config(name)
      meta = capability_meta[name.to_sym]
      meta ? meta[:config] : {}
    end

    # Generate a commented world.hec config block for a capability.
    #
    # @param name [Symbol] capability name
    # @return [String] commented config block, or empty string
    def capability_config_template(name)
      meta = capability_meta[name.to_sym]
      return "" unless meta && meta[:config].any?

      lines = ["  # #{name}"]
      lines << "  # #{meta[:description]}" unless meta[:description].empty?
      lines << "  # #{name} do"
      meta[:config].each do |key, opts|
        desc = opts[:desc] ? "  # #{opts[:desc]}" : ""
        lines << "  #   #{key} #{opts[:default].inspect}#{desc}"
      end
      lines << "  # end"
      lines.join("\n")
    end
  end
end
