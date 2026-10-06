require_relative "../doors/ruby_door"
require_relative "../ports/loading"
require_relative "../ports/persistence"
require_relative "dispatcher"
require_relative "remote_dispatcher"
require_relative "boot_gates"
require_relative "registry"
require_relative "loader/boot_steps"
require_relative "loader/described"

module Hecks
  module Runtime
    # Boots a domain: loads its bluebook directory into a fresh Registry, runs
    # every boot gate, and hands back the bound Dispatcher (or RemoteDispatcher).
    class Loader
      extend BootSteps

      # Default for a boot's `environment:` keyword: read `HECKS_ENVIRONMENT`. An explicit
      # `nil` means no overlay, whatever the variable holds.
      FROM_ENV = :from_env

      # Boots `path`: loads its bluebook directory into a fresh Registry, runs
      # every registered boot gate, and returns the bound dispatcher. Pass
      # `install_doors: false` to skip the `Widget::Item.Add(...)` global
      # facade sugar (only a caller dispatching by FQN string needs to).
      #
      # @param path [String] a domain directory to boot
      # @param shared [String, nil] shared ports/adapters root; nil walks up from `path`
      # @param environment [String, nil] environment overlay loaded after the domain; defaults
      #   to `HECKS_ENVIRONMENT`, and an explicit nil loads none
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted dispatcher
      # @raise [Errno::ENOENT] if `path` names no domain directory
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem
      def self.boot(path, shared: nil, install_doors: true, environment: FROM_ENV)
        described = describe(path, shared: shared, environment: environment)
        boot_described(described, install_doors: install_doors)
      end

      # Finishes a boot from declarations `describe` already loaded: runs every boot gate and binds
      # the dispatcher, without reading the domain's files again.
      #
      # @param described [Described] what `describe` answered for the domain to boot
      # @param install_doors [Boolean] install the `Widget::Item.Add(...)` global facade sugar
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted dispatcher
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem
      def self.boot_described(described, install_doors: true)
        registry = described.registry
        run_boot_gates!(registry, described.directory)
        dispatcher = dispatcher_for(registry)
        redrive_outbox!(dispatcher)
        seed_privacy_markings!(dispatcher, registry)
        install_doors ? bind_runtime(dispatcher) : dispatcher
      end

      # Loads `path`'s declarations into a fresh Registry and stops: no boot gate runs, no
      # persistence adapter is resolved or bound, nothing connects to a database.
      #
      # This is what answers a question about the domain's own shape (its verbs, arguments and
      # usage) in any environment, including one where the bound adapter cannot load.
      #
      # @param path [String] a domain directory to read
      # @param shared [String, nil] shared ports/adapters root; nil walks up from `path`
      # @param environment [String, nil] environment overlay loaded after the domain
      # @return [Described] answers `registry` like a booted dispatcher does
      # @raise [Errno::ENOENT] if `path` names no domain directory
      def self.describe(path, shared: nil, environment: FROM_ENV)
        loading   = Ports::Loading.bootstrap
        directory = loading.bluebook_directory(path)
        overlay   = selected_environment(environment)

        Described.new(directory) { load_declarations(loading, directory, shared, overlay) }
      end

      # Loads the directory's declarations into a fresh Registry, answering it.
      def self.load_declarations(loading, directory, shared, overlay)
        root     = loading.shared_root(shared, directory)
        registry = Registry.new(root: File.dirname(directory))

        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(root)
          loading.load_domain(directory, environment: overlay)
        end
        registry
      end

      # The overlay a boot loads: the caller's own choice (nil meaning none), else the
      # `HECKS_ENVIRONMENT` variable when the caller left the keyword at its default. A domain
      # with no `environments/<name>.*` files ignores either.
      #
      # @param environment [String, nil, Symbol] the overlay a caller passed, or `FROM_ENV`
      # @return [String, nil] the overlay name; nil for none
      def self.selected_environment(environment)
        return environment unless environment == FROM_ENV

        named = ENV["HECKS_ENVIRONMENT"].to_s.strip
        named.empty? ? nil : named
      end

      # Redrives pending outbox rows after the dispatcher and saga
      # rehydration both exist (a redriven row may advance a saga, which
      # must already be in memory). Claimed rows are surfaced, never
      # auto-redriven — see `Runtime::Outbox`. A no-op for a remote dispatcher.
      def self.redrive_outbox!(dispatcher)
        return unless dispatcher.respond_to?(:outbox)

        dispatcher.outbox.redrive!
      end

      # Boots the exact bluebook/hecksagon/world files in `paths`, in place —
      # unlike `boot`, no directory globbing and no copying into a temp dir
      # (a `persisted_by` path must resolve against the real project root,
      # not a copy's).
      #
      # @param paths [Array<String>, String] the exact file paths to boot, in load order
      # @param shared [String, nil] shared ports/adapters root; nil walks up from the first path
      # @param environment [String, nil] environment overlay loaded after the named files;
      #   defaults to `HECKS_ENVIRONMENT`, and an explicit nil loads none
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted dispatcher
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem
      def self.boot_files(paths, shared: nil, install_doors: true, environment: FROM_ENV)
        loading   = Ports::Loading.bootstrap
        files     = Array(paths).map { |path| File.expand_path(path) }
        directory = File.dirname(files.first)
        registry  = load_files(loading, files, shared, selected_environment(environment))

        run_boot_gates!(registry, directory)
        dispatcher = dispatcher_for(registry)
        install_doors ? bind_runtime(dispatcher) : dispatcher
      end

      # Loads exactly `files` into a fresh Registry rooted beside their directory, answering it.
      def self.load_files(loading, files, shared, overlay)
        directory = File.dirname(files.first)
        root      = loading.shared_root(shared, directory)
        registry  = Registry.new(root: File.dirname(directory))

        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(root)
          loading.load_selected(files, environment: overlay)
        end
        registry
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
        Doors::RubyDoor.install(dispatcher)
        dispatcher
      end
    end
  end
end
