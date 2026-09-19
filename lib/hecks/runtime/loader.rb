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
      # Ruby constant on `Object` per domain and per aggregate name, with
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
      #
      # @param path [String] a domain directory to boot, resolved through
      #   `Ports::Loading#bluebook_directory`
      # @param shared [String, nil] an explicit shared ports/adapters root override; nil
      #   resolves it by walking up from the domain directory
      # @param install_facade [Boolean] whether to install the `Widget::Item.Add(...)`
      #   facade sugar
      # @param environment [String, nil] the environment overlay to load after the
      #   domain's own files (e.g. `"production"`); nil loads none
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted dispatcher
      # @raise [Errno::ENOENT] if `path` names neither a domain directory nor one holding
      #   a `bluebook/` subdirectory
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem (an undeclared
      #   bind, a compute/rekey rule with no persistence plugin loaded, …)
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
        redrive_outbox!(dispatcher)
        seed_privacy_markings!(dispatcher, registry)
        install_facade ? bind_runtime(dispatcher) : dispatcher
      end

      # The outbox's boot-time reconciliation — after the dispatcher
      # exists (a row's consumer runs through its interpreters, so this
      # cannot be a plain registry gate the way saga rehydration is) and
      # after saga rehydration (a redriven row may advance a saga, which
      # must already be in memory). `pending` rows are redriven —
      # provably never started; `claimed` rows are surfaced, never
      # auto-redriven — see `Runtime::Outbox`. A remote dispatcher has
      # no local stores to scan.
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the
      #   just-booted dispatcher; a no-op unless it exposes an `outbox`
      # @return [void]
      def self.redrive_outbox!(dispatcher)
        return unless dispatcher.respond_to?(:outbox)

        dispatcher.outbox.redrive!
      end

      # Turns every `.hecksagon`-declared `AggregateDoor#mark_sensitive` fact into a real
      # `Privacy::Marking.Mark` — after the dispatcher exists (dispatch needs a bound
      # repository), idempotent across reboots (a marking already present is never
      # re-dispatched, the same "provably never started" restraint `redrive_outbox!`
      # holds itself to above). A no-op when nothing declared one, or when the domain
      # never attached Privacy at all.
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the just-booted
      #   dispatcher `Privacy::Marking.Mark` dispatches through
      # @param registry [Runtime::Registry] the just-booted registry `pending_privacy_markings`
      #   was recorded on
      # @return [void]
      def self.seed_privacy_markings!(dispatcher, registry)
        return if registry.pending_privacy_markings.empty?
        return unless registry.bluebook("Privacy")

        already_marked_by_domain = registry.pending_privacy_markings.map { |marking| marking[:domain] }.uniq.to_h do |domain|
          [domain, dispatcher.query("Privacy::Marking.ForDomain", domain: domain).map { |row| row[:attribute_path][:value] }]
        end

        registry.pending_privacy_markings.each do |marking|
          next if already_marked_by_domain[marking[:domain]].include?(marking[:attribute_path])

          dispatcher.dispatch_flat("Privacy::Marking.Mark", marking)
        end
      end

      # The explicit-file form — `paths` names the exact bluebook/hecksagon/
      # world files to boot, in place, wherever they actually live. `boot`
      # above only ever takes a directory and globs it; that is the right
      # shape for a real deployment (`examples/banking`, a domain someone
      # `cd`s into), and the wrong one for a caller that wants to declare a
      # narrow, explicit scope and have it booted exactly as declared — a
      # `.behaviors` file's own `loads` line is the motivating caller
      # (`Hecks::Behaviors`), but this carries no behaviors-specific
      # logic and is not gated behind requiring that module.
      #
      # No copying, no temp directory. A prior port of this same idea
      # (vendored into a downstream consumer, read before writing this)
      # scoped a per-test boot by copying files into `Dir.mktmpdir` — which
      # destroys real relative paths, and worse, makes a `persisted_by`
      # path resolve against the temp copy's root instead of the project's
      # own (confirmed there: a file adapter kept reading and writing the
      # same deterministic tmp copy across an entire session, because
      # `Hecks.boot`'s own `root` is always `File.dirname` of whatever
      # directory it was handed). `directory` here is `File.dirname` of the
      # first real path in `paths` — genuinely on disk, not a copy — so
      # every downstream path (`EraCheck`, `persisted_by`, `shared_root`)
      # resolves exactly as an ordinary directory boot's would.
      #
      # @param paths [Array<String>, String] the exact bluebook/hecksagon/world file paths
      #   to boot, in the order they should load
      # @param shared [String, nil] an explicit shared ports/adapters root override; nil
      #   resolves it by walking up from `File.dirname` of the first path
      # @param install_facade [Boolean] whether to install the `Widget::Item.Add(...)`
      #   facade sugar
      # @param environment [String, nil] the environment overlay to load after the
      #   named files (e.g. `"production"`); nil loads none
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted dispatcher
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem (an undeclared
      #   bind, a compute/rekey rule with no persistence plugin loaded, …)
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

      # Runs every registered boot gate against `registry`, in order.
      #
      # ADR 0031 — a per-boot `BootGates` instance holds exactly the gates this
      # registry's own bound adapters have a capability for, rather than two
      # hardcoded, unconditional calls. Ordering is
      # preserved: era-checking (when a persistence plugin contributes one)
      # still runs before `verify!`, saga rehydration still runs after
      # (conservative — see `SagaPersistence#rehydrate_sagas!`'s own
      # comment).
      #
      # ADR 0033 — this loader no longer names `EraCheck`, or any other
      # era-specific class, at all. Every loaded persistence plugin
      # (`Ports::Persistence.each_plugin` — nothing here if nothing was
      # ever `require`d) is asked to contribute its own `:pre_verify`/
      # `:post_verify` gates generically; `:saga_rehydration` is the one
      # gate core still registers directly, because ADR 0031 already
      # proved it's not era-specific.
      #
      # @param registry [Runtime::Registry] the registry mid-boot, with its bluebooks,
      #   hecksagons, ports, adapters and worlds already loaded
      # @param directory [String] the domain directory the gates report against in a refusal
      # @return [Runtime::BootGates] the gates instance built and run for this boot
      # @raise [Runtime::WiringError] if `registry.verify!` or any contributed gate finds
      #   a wiring problem
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
      # compute/rekey rule at all." A loaded persistence plugin (e.g. the
      # era plugin's own `:era_compute_rules` gate, registered above) runs
      # the real, adapter-aware version of this check and refuses by name
      # ("...is bound to Memory") long before this ever would; this only
      # fires when nothing did, because nothing was loaded to.
      #
      # @param registry [Runtime::Registry] the registry mid-boot, whose declared
      #   `translations` are checked
      # @return [void]
      # @raise [Runtime::WiringError] if any translation declares a `computes`/`rekeys`
      #   rule while no persistence plugin is loaded to interpret it
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
      # `Dispatcher` otherwise — the one place this decision gets
      # made, so everything built on top (`Handle`, `AggregateDoor`,
      # `Facade::Surface`) never has to know which class it's holding.
      # `registry.bluebooks.keys.first` is the just-booted domain's own
      # name (insertion order — the target's own bluebook loads before
      # any `uses_framework` chapter, `bin/project_rust`'s own header
      # draws the identical distinction), not a directory basename.
      #
      # `dispatched_by("Lambda")` is its own, explicit verb — not
      # inferred from `deployed_to("AwsLambda")`'s mere presence. Both
      # Banking's and Embryonaut's `.world` files already declare
      # `deployed_to("AwsLambda")` (it only means "a deploy target
      # exists"), so treating that alone as "boot this domain against
      # Lambda" would have silently rerouted Banking's every local
      # boot — every spec, every `bin/console` session — the moment
      # this landed. A domain opts in explicitly, the same way
      # `persisted_by("PostgresEra")` is never inferred from anything
      # else either.
      #
      # @param registry [Runtime::Registry] the just-booted registry, whose just-booted
      #   domain's `.world` is checked for `dispatched_by("Lambda")`
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] a `RemoteDispatcher`
      #   bound to `registry` if the domain declares `dispatched_by("Lambda")`, a plain
      #   `Dispatcher` otherwise
      def self.dispatcher_for(registry)
        domain = registry.bluebooks.keys.first
        settings = registry.world(domain)&.for_verb("dispatched_by") || {}
        return Dispatcher.new(registry) unless settings[:adapter] == "Lambda"

        RemoteDispatcher.new(registry, region: settings.fetch(:region, "us-east-1"), function: settings[:function])
      end

      # Installs the facade sugar (`Widget::Item.Add(...)`), closed over
      # `dispatcher`, and hands `dispatcher` back.
      #
      # The door is installed here, not stamped: the facade's modules close
      # over this dispatcher, so the binding lives in the surface a boot
      # installs rather than in a class-level global (`ruby_class.runtime =`
      # on every aggregate's class) that would make two boots in one process
      # share one name.
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the
      #   just-booted dispatcher the facade should call into
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] `dispatcher`, unchanged
      def self.bind_runtime(dispatcher)
        Facade::Surface.install(dispatcher)
        dispatcher
      end
    end
  end
end
