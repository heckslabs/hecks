require "tempfile"
require_relative "memory_ports"

# Boots a domain written inline, on the Memory adapter. A rule's predicate is read back from the
# source file it was declared in, so the source goes to a file of its own and is evaluated from it.
module BootedSource
  module_function

  # @param source [String] the bluebook text
  # @param authorization [Boolean] whether to load the authorization port and its Governance adapter
  # @yield declares the hecksagon, inside the boot's registry
  # @return [Hecks::Runtime::Dispatcher] the booted domain's dispatcher
  def boot(source, authorization: false, &)
    file = Tempfile.new(["inline-", ".bluebook"])
    file.write(source)
    file.flush
    registry = declare(source, file.path, authorization, &)
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  ensure
    file&.close!
  end

  # @return [Hecks::Runtime::Registry] a registry holding the declared domain
  def declare(source, path, authorization, &)
    Hecks::Runtime::Registry.new.tap do |registry|
      Hecks.with_registry(registry) do
        MemoryPorts.load!
        load_authorization if authorization
        Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
        yield
      end
    end
  end

  # Loads the authorization port and the adapter that answers it from Governance's grants.
  def load_authorization
    %w[ports/authorization.port adapters/driven/governance_authorization.adapter].each do |file|
      Kernel.load(File.expand_path("../../lib/hecks/#{file}", __dir__))
    end
  end
end
