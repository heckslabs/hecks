require_relative "../../runtime/registry"

module Hecks
  module Ports
    module Persistence
      # Adapter shape for an interpreter behind a call boundary: no local log, so writes raise.
      # Detect it with `registry.adapter_class(name) <= RemoteRuntime`, not by adapter name.
      module RemoteRuntime
        # Refuses every local write; `project` is an alias and refuses the same way.
        #
        # @return [void] never returns
        # @raise [Runtime::WiringError] always, pointing the caller at `Runtime::RemoteDispatcher`
        def append(*)
          raise Runtime::WiringError,
                "#{self.class.name} is a remote-runtime delegate — dispatch through " \
                "Runtime::RemoteDispatcher instead of writing through the repository directly"
        end
        alias project append

        # Reports an empty journal, since a remote-runtime delegate keeps no local log.
        #
        # @return [Array] always `[]`
        def entries = []
      end
    end
  end
end
