require_relative "../facade/surface"
require_relative "../ports/loading"
require_relative "../ports/persistence"
require_relative "dispatcher"
require_relative "remote_dispatcher"
require_relative "boot_gates"
require_relative "registry"

module Hecks
  module Runtime
    # Boots a domain: loads its bluebook directory into a fresh Registry, runs
    # every boot gate, and hands back the bound Dispatcher (or RemoteDispatcher).
    class Loader
      # Boots `path`: loads its bluebook directory into a fresh Registry, runs
      # every registered boot gate, and returns the bound dispatcher. Pass
      # `install_facade: false` to skip the `Widget::Item.Add(...)` global
      # facade sugar (only a caller dispatching by FQN string needs to).
      #
      # @param path [String] a domain directory to boot
      # @param shared [String, nil] shared ports/adapters root; nil walks up from `path`
      # @param environment [String, nil] environment overlay loaded after the domain; nil for none
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted dispatcher
      # @raise [Errno::ENOENT] if `path` names no domain directory
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem
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

      # Redrives pending outbox rows after the dispatcher and saga
      # rehydration both exist (a redriven row may advance a saga, which
      # must already be in memory). Claimed rows are surfaced, never
      # auto-redriven — see `Runtime::Outbox`. A no-op for a remote dispatcher.
      def self.redrive_outbox!(dispatcher)
        return unless dispatcher.respond_to?(:outbox)

        dispatcher.outbox.redrive!
      end

      # Turns every `.hecksagon`-declared `mark_sensitive` fact into a real
      # `Privacy::Marking.Mark`. Idempotent across reboots — a marking already
      # present is never re-dispatched. A no-op when nothing declared one, or
      # the domain never attached Privacy at all.
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

      # Boots the exact bluebook/hecksagon/world files in `paths`, in place —
      # unlike `boot`, no directory globbing and no copying into a temp dir
      # (a `persisted_by` path must resolve against the real project root,
      # not a copy's).
      #
      # @param paths [Array<String>, String] the exact file paths to boot, in load order
      # @param shared [String, nil] shared ports/adapters root; nil walks up from the first path
      # @param environment [String, nil] environment overlay loaded after the named files
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted dispatcher
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem
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

      # Runs every registered boot gate against `registry`, in order:
      # era-checking (if a plugin contributes one) before `verify!`, saga
      # rehydration after. No era-specific class is named here — each loaded
      # persistence plugin contributes its own gates generically (ADR 0031).
      def self.run_boot_gates!(registry, directory)
        gates = BootGates.new
        load_bound_adapters!(registry)
        Ports::Persistence.each_plugin { |plugin| plugin.contribute_boot_gates(registry, gates) }
        check_compute_rules_backstop!(registry)

        gates.run!(:pre_verify, registry, directory)
        registry.verify!

        gates.register(:saga_rehydration, ->(reg, _dir) { reg.rehydrate_sagas! }, phase: :post_verify) if
          registry.saga_domains.any? { |domain| registry.saga_persistence(domain) != Ports::Persistence::NULL_SAGA_STORE }
        gates.run!(:post_verify, registry, directory)
        gates
      end

      # Resolves the Ruby implementation of every adapter a hecksagon binds.
      # An adapter's implementation can register its own persistence plugin as
      # a side effect of loading (e.g. `PostgresEra`) — resolving here, before
      # gates are collected, is what registers those plugins' gates without
      # the app requiring them itself. A bind with no implementation is left
      # for `verify!` to refuse.
      def self.load_bound_adapters!(registry)
        registry.hecksagons.each_value do |hexagon|
          hexagon.binds.each do |bind|
            registry.adapter_class(bind.adapter)
          rescue WiringError
            next
          end
        end
      end

      # A backstop only: fires when a translation declares a `computes`/
      # `rekeys` rule but no persistence plugin is loaded to interpret it.
      # Any loaded plugin's own compute-rules gate refuses earlier, by name,
      # whenever one is loaded — this only runs when nothing was.
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

      # `RemoteDispatcher` for a domain declaring `dispatched_by("Lambda")`,
      # `Dispatcher` otherwise. That's an explicit opt-in, never inferred from
      # `deployed_to("AwsLambda")` alone — that verb only means a deploy
      # target exists, and treating it as "dispatch via Lambda" would reroute
      # every local boot of a domain that merely declares one.
      def self.dispatcher_for(registry)
        domain = registry.bluebooks.keys.first
        settings = registry.world(domain)&.for_verb("dispatched_by") || {}
        return Dispatcher.new(registry) unless settings[:adapter] == "Lambda"

        RemoteDispatcher.new(registry, region: settings.fetch(:region, "us-east-1"), function: settings[:function])
      end

      # Installs the facade sugar (`Widget::Item.Add(...)`) closed over
      # `dispatcher`. The binding lives in the facade's own modules, not a
      # class-level global, so two boots in one process don't share one name.
      def self.bind_runtime(dispatcher)
        Facade::Surface.install(dispatcher)
        dispatcher
      end
    end
  end
end
