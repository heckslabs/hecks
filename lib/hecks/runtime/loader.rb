require_relative "../facade/surface"
require_relative "../ports/loading"
require_relative "../ports/persistence"
require_relative "dispatcher"
require_relative "remote_dispatcher"
require_relative "boot_gates"
require_relative "registry"

module Hecks
  module Runtime
    # The boot entry point: loads a bluebook directory (or an explicit
    # file list) into a fresh Registry, runs every registered boot gate
    # (era checks, saga rehydration, …), and hands back the Dispatcher
    # (or RemoteDispatcher, for a domain declaring `dispatched_by
    # ("Lambda")`) bound to it — installing the `Widget::Item.Add(...)`
    # facade sugar unless the caller opts out.
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
      # for the mechanism. hecks never reads ENV itself (every other
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

        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(root)
          loading.load_domain(directory, environment: environment)
        end

        run_boot_gates!(registry, directory)
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
      # (`Hecks::Behaviors`), but this carries no behaviors-specific
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

        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(root)
          loading.load_selected(files, environment: environment)
        end

        run_boot_gates!(registry, directory)
        dispatcher = dispatcher_for(registry)
        install_facade ? bind_runtime(dispatcher) : dispatcher
      end

      # ADR 0031 — replaces two previously-hardcoded, unconditional calls
      # with a per-boot `BootGates` instance holding exactly the gates THIS
      # registry's own bound adapters have a capability for. Ordering is
      # preserved: era-checking (when a persistence plugin contributes one)
      # still runs before `verify!`, saga rehydration still runs after
      # (conservative — see `SagaPersistence#rehydrate_sagas!`'s own
      # comment).
      #
      # ADR 0033 — this loader no longer names `EraCheck`, or any other
      # era-specific class, at all. Every LOADED persistence plugin
      # (`Ports::Persistence.each_plugin` — nothing here if nothing was
      # ever `require`d) is asked to contribute its own `:pre_verify`/
      # `:post_verify` gates generically; `:saga_rehydration` is the one
      # gate core still registers directly, because ADR 0031 already
      # proved it's not era-specific.
      def self.run_boot_gates!(registry, directory)
        gates = BootGates.new
        Ports::Persistence.each_plugin { |plugin| plugin.contribute_boot_gates(registry, gates) }
        check_compute_rules_backstop!(registry)

        gates.run!(:pre_verify, registry, directory)
        registry.verify!

        gates.register(:saga_rehydration, ->(reg, _dir) { reg.rehydrate_sagas! }, phase: :post_verify) if
          registry.hecksagons.each_key.any? { |domain| registry.saga_persistence(domain) != Ports::Persistence::NULL_SAGA_STORE }
        gates.run!(:post_verify, registry, directory)
        gates
      end

      # The one piece of the old, era-owned `check_compute_rules!` core
      # still carries — deliberately thinner. `registry.translations` is
      # plain `Bluebook::Translation`/`TranslationAggregate`/
      # `TranslationCompute`/`TranslationRekey` data (`bluebook/
      # translation.rb`, core, no era-specific class involved), so this
      # needs nothing plugin-specific to ask "does anything declare a
      # compute/rekey rule at all." A LOADED persistence plugin (e.g. the
      # era plugin's own `:era_compute_rules` gate, registered above) runs
      # the real, adapter-aware version of this check and refuses by name
      # ("...is bound to Memory") long before this ever would; this only
      # fires when nothing did, because nothing was loaded to.
      def self.check_compute_rules_backstop!(registry)
        return if Ports::Persistence.plugins_loaded?

        registry.translations.each do |translation|
          translation.aggregates.each do |aggregate|
            next if aggregate.computes.empty? && aggregate.rekeys.empty?

            raise WiringError,
                  "cannot boot #{translation.domain}::#{aggregate.name}: a compute/rekey rule is declared, but no " \
                  "persistence plugin that can interpret it is loaded (e.g. require " \
                  "\"hecks/ports/persistence/plugins/era\")"
          end
        end
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
