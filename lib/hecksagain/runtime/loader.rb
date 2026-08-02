require_relative "../facade/surface"
require_relative "../ports/loading"
require_relative "dispatcher"
require_relative "era_check"
require_relative "registry"

module Hecksagain
  module Runtime
    class Loader
      def self.boot(path, shared: nil)
        loading   = Ports::Loading.bootstrap
        directory = loading.bluebook_directory(path)
        root      = loading.shared_root(shared, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          loading.load_library      
          loading.load_project(root) 
          loading.load_domain(directory)
        end

        # The era gate runs BEFORE verify! builds repositories: minting an
        # era (Postgres) must have created its partition and head views
        # before any adapter opens them, and a refused era must refuse
        # before any adapter touches data.
        EraCheck.check!(registry, directory)
        registry.verify!
        bind_runtime(Dispatcher.new(registry))
      end

      # THE DOOR IS INSTALLED HERE, NOT STAMPED. This used to write the
      # dispatcher onto every aggregate's class (`ruby_class.runtime =`) — the
      # class-level global that made two runtimes in one process share one
      # name. The facade's modules close over THIS dispatcher instead, so the
      # binding lives in the surface a boot installs, not on anything shared.
      def self.bind_runtime(dispatcher)
        Facade::Surface.install(dispatcher)
        dispatcher
      end
    end
  end
end
