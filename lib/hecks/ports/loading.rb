require_relative "../runtime/errors"
require_relative "adapter_registry"

module Hecks
  module Ports
    # The `loading` port: `bootstrap` hands back the adapter that reads bluebook files off disk to
    # build the very first registry, before any other port has a registry to resolve against.
    #
    # The adapter registers itself here as it loads (`Adapters::Folder` does), so the port names
    # no adapter of its own.
    module Loading
      NAME = "loading".freeze

      module_function

      # Names the adapter class every boot starts loading with. The adapter is also recorded in
      # the adapter registry with the `loading` capability.
      #
      # @param adapter [Class] a class whose bare `.new` answers the loading port's methods
      # @return [Class] the same class
      def bootstrap_with(adapter)
        name = adapter.name ? adapter.name.split("::").last : adapter.inspect
        AdapterRegistry.register(name, adapter, provides: [NAME])
      end

      # Builds the loader a boot starts from, before any registry exists to resolve one.
      #
      # @return [Object] a new instance of the registered loading adapter, with no settings
      # @raise [Runtime::WiringError] if no loading adapter has registered itself
      def bootstrap
        _name, klass = AdapterRegistry.lookup(NAME).last
        raise Runtime::WiringError, "no adapter has registered for the #{NAME} port" unless klass

        klass.new
      end
    end
  end
end
