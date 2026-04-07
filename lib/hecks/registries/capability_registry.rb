# Hecks::CapabilityRegistryMethods
#
# Registry for domain capabilities. Capabilities enrich the domain IR by
# generating constructs (commands, repository bindings) at runtime. Unlike
# extensions which add infrastructure behavior, capabilities modify what
# the domain can do.
#
#   Hecks.register_capability(:crud) { |runtime| CrudCapability.apply(runtime) }
#   Hecks.capability_registry  # => { crud: #<Proc> }
#
module Hecks
  # Hecks::CapabilityRegistryMethods
  #
  # Registry for domain capabilities that enrich the domain IR by generating constructs at runtime.
  #
  module CapabilityRegistryMethods
    def capability_registry
      @capability_registry ||= Registry.new
    end

    def register_capability(name, &hook)
      capability_registry.register(name, hook)
    end
  end
end
