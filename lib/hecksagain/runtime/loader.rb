require_relative "../facade/surface"
require_relative "../ports/loading"
require_relative "dispatcher"
require_relative "remote_dispatcher"
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
        bind_runtime(dispatcher_for(registry))
      end

      # `RemoteDispatcher` for a domain routed through Lambda,
      # `Dispatcher` otherwise — the ONE place this decision gets
      # made, so everything built on top (`Handle`, `AggregateDoor`,
      # `Facade::Surface`) never has to know which class it's holding.
      # `registry.bluebooks.keys.first` is the just-booted domain's own
      # name (insertion order — the target's own bluebook loads before
      # any `uses_framework` chapter, `bin/project_rust`'s own header
      # draws the identical distinction), not a directory basename.
      #
      # `dispatched_by("Lambda")` is its OWN, EXPLICIT verb — NOT
      # inferred from `deployed_to("AwsLambda")`'s mere presence. Both
      # Banking's and Embryonaut's `.world` files already declare
      # `deployed_to("AwsLambda")` (it only means "a deploy target
      # exists"), so treating that alone as "boot this domain against
      # Lambda" would have silently rerouted Banking's every local
      # boot — every spec, every `bin/console` session — the moment
      # this landed. A domain opts in explicitly, the same way
      # `persisted_by("Postgres")` is never inferred from anything
      # else either.
      def self.dispatcher_for(registry)
        domain = registry.bluebooks.keys.first
        settings = registry.world(domain)&.for_verb("dispatched_by") || {}
        return Dispatcher.new(registry) unless settings[:adapter] == "Lambda"

        RemoteDispatcher.new(registry, region: settings.fetch(:region, "us-east-1"))
      end

      # THE DOOR IS INSTALLED HERE, NOT STAMPED. This used to write the
      # dispatcher onto every aggregate's class (`ruby_class.runtime =`) — the
      # class-level global that made two boots in one process share one
      # name. The facade's modules close over THIS dispatcher instead, so the
      # binding lives in the surface a boot installs, not on anything shared.
      def self.bind_runtime(dispatcher)
        Facade::Surface.install(dispatcher)
        dispatcher
      end
    end
  end
end
