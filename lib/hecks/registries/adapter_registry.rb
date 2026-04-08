# Hecks::AdapterRegistryMethods
#
# Registry for persistence adapter types. Each adapter (memory, sqlite, etc.)
# registers itself so that BluebookConnections and Boot can check adapter
# availability without hardcoded lists.
#
#   Hecks.register_adapter(:sqlite)
#   Hecks.registered_adapters  # => [:memory, :sqlite, ...]
#   Hecks.adapter?(:sqlite)    # => true
#
module Hecks
  # Hecks::AdapterRegistryMethods
  #
  # Registry for persistence adapter types (memory, sqlite, etc.) extended onto the Hecks module.
  #
  module AdapterRegistryMethods
    def registered_adapters
      adapter_registry.all
    end

    def register_adapter(name)
      adapter_registry.register(name)
    end

    def adapter?(name)
      adapter_registry.include?(name)
    end

    private

    def adapter_registry
      @adapter_registry ||= SetRegistry.new(%i[memory sqlite postgres mysql mysql2 filesystem filesystem_store mongodb])
    end
  end
end
