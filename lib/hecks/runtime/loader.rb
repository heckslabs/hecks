require_relative "../ports/loading"
require_relative "../ports/persistence"
require_relative "../ports/dispatch"
require_relative "dispatcher"
require_relative "boot_gates"
require_relative "registry"
require_relative "loader/boot_steps"
require_relative "loader/described"

module Hecks
  module Runtime
    # Boots a domain: loads its bluebook directory into a fresh Registry, runs
    # every boot gate, and hands back the dispatcher the domain's world names.
    #
    # It reads no environment variable and installs no driving adapter: `Hecks::Assembly`
    # chooses the overlay and plugs the Ruby facade in.
    class Loader
      extend BootSteps

      # Boots `path`: loads its bluebook directory into a fresh Registry, runs
      # every registered boot gate, and returns the dispatcher.
      #
      # @param path [String] a domain directory to boot
      # @param shared [String, nil] shared ports/adapters root; nil walks up from `path`
      # @param environment [String, nil] environment overlay loaded after the domain; nil loads none
      # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted dispatcher
      # @raise [Errno::ENOENT] if `path` names no domain directory
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem
      def self.boot(path, shared: nil, environment: nil)
        boot_described(describe(path, shared: shared, environment: environment))
      end

      # Finishes a boot from declarations `describe` already loaded: runs every boot gate and builds
      # the dispatcher, without reading the domain's files again.
      #
      # @param described [Described] what `describe` answered for the domain to boot
      # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted dispatcher
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem
      def self.boot_described(described)
        registry = described.registry
        run_boot_gates!(registry, described.directory)
        dispatcher = dispatcher_for(registry)
        redrive_outbox!(dispatcher)
        seed_privacy_markings!(dispatcher, registry)
        dispatcher
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
      def self.describe(path, shared: nil, environment: nil)
        loading   = Ports::Loading.bootstrap
        directory = loading.bluebook_directory(path)

        Described.new(directory) { load_declarations(loading, directory, shared, environment) }
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
      # @param environment [String, nil] environment overlay loaded after the named files; nil
      #   loads none
      # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted dispatcher
      # @raise [Runtime::WiringError] if a boot gate finds a wiring problem
      def self.boot_files(paths, shared: nil, environment: nil)
        loading   = Ports::Loading.bootstrap
        files     = Array(paths).map { |path| File.expand_path(path) }
        directory = File.dirname(files.first)
        registry  = load_files(loading, files, shared, environment)

        run_boot_gates!(registry, directory)
        dispatcher_for(registry)
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

      # The local `Dispatcher`, unless the domain's world binds the dispatch port: then the bound
      # adapter builds the dispatcher (`dispatched_by("Lambda")` routes writes to a Lambda). That
      # is an explicit opt-in, never inferred from `deployed_to("AwsLambda")` alone, which only
      # means a deploy target exists.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @return [Runtime::Dispatcher, Object] the dispatcher the boot hands back
      # @raise [Runtime::WiringError] if the bound adapter cannot build a dispatcher
      def self.dispatcher_for(registry)
        settings = registry.world(registry.bluebooks.keys.first)&.for_verb(Ports::Dispatch::VERB) || {}
        return Dispatcher.new(registry) unless settings[:adapter]

        Ports::Dispatch.dispatcher(registry, settings)
      end

      # Installs the Ruby facade over a dispatcher built by hand. See `Hecks.bind_runtime`.
      #
      # @param dispatcher [Runtime::Dispatcher] a dispatcher over a verified registry
      # @return [Runtime::Dispatcher] the same dispatcher
      def self.bind_runtime(dispatcher) = Hecks.bind_runtime(dispatcher)
    end
  end
end
