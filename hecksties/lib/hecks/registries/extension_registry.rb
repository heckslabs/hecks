# Hecks::ExtensionRegistryMethods
#
# Extension hook and metadata storage. Extracted from the Hecks module
# to give extensions a focused home. Each extension can declare an
# +adapter_type+ of +:driven+ (repos, validation, auth) or +:driving+
# (HTTP, queue, Slack). Boot fires driven extensions first so driving
# adapters see the final runtime.
#
#   Hecks.describe_extension(:sqlite,
#     description: "SQLite persistence",
#     adapter_type: :driven,
#     wires_to: :repository)
#
#   Hecks.driven_extensions  # => [:sqlite, :auth, ...]
#   Hecks.driving_extensions # => [:http, :slack, ...]
#
module Hecks
  module ExtensionRegistryMethods
    def extension_registry
      @extension_registry ||= Registry.new
    end

    def extension_meta
      @extension_meta ||= Registry.new
    end

    def register_extension(name, &hook)
      extension_registry.register(name, hook)
    end

    def describe_extension(name, description:, config: {}, wires_to: nil, adapter_type: nil)
      extension_meta.register(name, {
        description: description, config: config,
        wires_to: wires_to, adapter_type: adapter_type
      })
    end

    def alias_extension(alias_name, target_name)
      extension_registry[alias_name] = extension_registry[target_name]
      extension_meta[alias_name] = extension_meta[target_name] if extension_meta[target_name]
    end

    def driven_extensions
      extension_meta.select { |_, m| m[:adapter_type] == :driven }.map(&:first)
    end

    def driving_extensions
      extension_meta.select { |_, m| m[:adapter_type] == :driving }.map(&:first)
    end
  end
end
