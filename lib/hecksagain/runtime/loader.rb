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
      # `environment:` — see Adapters::Folder#load_domain's own comment
      # for the mechanism. hecksagain never reads ENV itself (every other
      # env-var lookup in this codebase lives in app-owned .world/
      # .hecksagon files, never library internals) — a caller resolves
      # its own env var name and passes the resulting string straight
      # through, e.g. `Hecks.boot(path, environment:
      # ENV.fetch("MYAPP_ENV", "development"))`.
      def self.boot(path, shared: nil, install_facade: true, environment: nil)
        loading   = Ports::Loading.bootstrap
        directory = loading.bluebook_directory(path)
        root      = loading.shared_root(shared, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          loading.load_library
          loading.load_project(root)
          loading.load_domain(directory, environment: environment)
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

      # THE EXPLICIT-FILE FORM — `paths` names the exact bluebook/hecksagon/
      # world files to boot, in place, wherever they actually live. `boot`
      # above only ever takes a directory and globs it; that is the right
      # shape for a real deployment (`examples/banking`, a domain someone
      # `cd`s into), and the wrong one for a caller that wants to declare a
      # narrow, explicit scope and have it booted exactly as declared — a
      # `.behaviors` file's own `loads` line is the motivating caller
      # (`Hecksagain::Behaviors`), but this carries no behaviors-specific
      # logic and is not gated behind requiring that module.
      #
      # NO COPYING, NO TEMP DIRECTORY. A prior port of this same idea
      # (vendored into a downstream consumer, read before writing this)
      # scoped a per-test boot by copying files into `Dir.mktmpdir` — which
      # destroys real relative paths, and worse, makes a `persisted_by`
      # path resolve against the TEMP copy's root instead of the project's
      # own (confirmed there: a file adapter kept reading and writing the
      # same deterministic tmp copy across an entire session, because
      # `Hecks.boot`'s own `root` is always `File.dirname` of whatever
      # directory it was handed). `directory` here is `File.dirname` of the
      # FIRST real path in `paths` — genuinely on disk, not a copy — so
      # every downstream path (`EraCheck`, `persisted_by`, `shared_root`)
      # resolves exactly as an ordinary directory boot's would.
      def self.boot_files(paths, shared: nil, install_facade: true, environment: nil)
        loading   = Ports::Loading.bootstrap
        files     = Array(paths).map { |path| File.expand_path(path) }
        directory = File.dirname(files.first)
        root      = loading.shared_root(shared, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecksagain.with_registry(registry) do
          loading.load_library
          loading.load_project(root)
          loading.load_selected(files, environment: environment)
        end

        EraCheck.check!(registry, directory)
        registry.verify!
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
