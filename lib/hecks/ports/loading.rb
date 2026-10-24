require_relative "../runtime/errors"

module Hecks
  module Ports
    # The `loading` port: `bootstrap` hands back the adapter that reads bluebook files off disk to
    # build the very first registry, before any other port has a registry to resolve against.
    #
    # The adapter registers itself here as it loads (`Adapters::Folder` does), so the port names
    # no adapter of its own.
    module Loading
      NAME = "loading".freeze

      @bootstrap = nil

      module_function

      # Names the adapter class every boot starts loading with.
      #
      # @param adapter [Class] a class whose bare `.new` answers the loading port's methods
      # @return [Class] the same class
      def bootstrap_with(adapter)
        @bootstrap = adapter
      end

      # Builds the loader a boot starts from, before any registry exists to resolve one.
      #
      # @return [Object] a new instance of the registered loading adapter, with no settings
      # @raise [Runtime::WiringError] if no loading adapter has registered itself
      def bootstrap
        raise Runtime::WiringError, "no adapter has registered for the #{NAME} port" unless @bootstrap

        @bootstrap.new
      end
    end
  end
end
