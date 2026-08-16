require_relative "../facade/surface"
require_relative "../ports/loading"
require_relative "dispatcher"
require_relative "remote_dispatcher"
require_relative "era_check"
require_relative "registry"

module Hecksagain
  module Runtime
    class Loader
      # `install_facade:` defaults on — every ordinary caller wants
      # `Widget::Item.Add(...)` sugar. A caller that only ever dispatches
      # by FQN string (`SmokeTest`, the one caller so far) can pass
      # `false` to skip it: `Facade::Surface.install` puts a bare global
      # Ruby constant on `Object` per domain AND per aggregate name, with
      # no scoping and no cleanup hook, so a tool booting arbitrary
      # throwaway domains under generic names ("Widget", "Item", "Tag")
      # would otherwise leak those names into the rest of the process —
      # measured, not hypothetical: this exact leak once made an
      # unrelated `dsl_spec.rb` example resolve a bare `Widget` constant
      # to a stale smoke-test facade from a deleted temp directory instead
      # of raising, corrupting that spec's own unrelated build. Skipping
      # the install is safe because nothing downstream of a raw
      # `Dispatcher` needs the sugar — `Dispatcher#dispatch`/`#query` work
      # identically either way.
      def self.boot(path, shared: nil, install_facade: true)
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
        # AFTER verify! (conservative — any wiring error surfaces first,
        # not strictly required since resolution only needs the
        # hecksagon binds, already loaded), BEFORE the dispatcher is
        # built — repopulates `saga_instances` from whatever durable
        # store each domain's own adapter answers with (§2-§4), so a
        # process manager mid-flight at the last shutdown/crash/cold-
        # start doesn't start this boot looking like it never began.
        registry.rehydrate_sagas!
        dispatcher = dispatcher_for(registry)
        install_facade ? bind_runtime(dispatcher) : dispatcher
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
      # `persisted_by("PostgresEra")` is never inferred from anything
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
