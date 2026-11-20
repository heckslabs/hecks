require_relative "../ir"
require_relative "../../runtime/loader"
require_relative "../../runtime/errors"
require_relative "../../ports/persistence/binding_policy"
require_relative "adapter_selection"

module Hecks
  module Behaviors
    module Expectations
      # Boots the runtime a behaviors suite's `loads` names, once per set of files and engine, and
      # refuses one that binds an aggregate to anything but Memory. The engine is the in-process
      # one or the Rust kernel, as `HECKS_ENGINE` says (see `Hecks::Assembly.selected_engine`); a
      # kernel boot never falls back to Ruby. Extended onto `Expectations`.
      module Boot
        # Cached per suite, keyed by `loads`' file paths and mtimes, so a boot is
        # reused across tests but an edited bluebook boots fresh on the next one.
        # Mutated in place (`RUNTIMES[key] ||= boot_and_guard(files)`).
        RUNTIMES      = {}
        RUNTIMES_LOCK = Mutex.new
        private_constant :RUNTIMES, :RUNTIMES_LOCK

        # Boots (or reuses the cached boot of) the runtime a suite's `loads` names. A boot that
        # failed is cached too, so a kernel that cannot be built is tried once, not once a test.
        #
        # @param suite [Behaviors::BehaviorsSuite] the suite whose `loads` files boot
        #   the runtime
        # @param engine [Symbol] `:ruby` or `:kernel`; `HECKS_ENGINE` when left out
        # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher,
        #   Runtime::KernelDispatcher] the cached or freshly booted, Memory-only-guarded runtime
        # @raise [Malformed] if any aggregate the suite boots is not bound to the
        #   default (Memory) adapter
        # @raise [RustBuild::KernelEngine::BinaryUnavailable] when the kernel cannot be built
        def runtime_for(suite, engine: Hecks::Assembly.selected_engine(Hecks::Assembly::FROM_ENV))
          files, adapters = suite_files(suite)
          key    = [engine] + boot_key(files + Array(adapters))
          booted = RUNTIMES_LOCK.synchronize { RUNTIMES[key] ||= boot_or_failure(engine, files, adapters) }
          raise booted if booted.is_a?(StandardError)

          booted
        end

        # @return [Array(Array<String>, Array<String>)] the suite's `loads`, absolute, and the
        #   `.adapter` files `AdapterSelection` chose for it (nil for a suite with no file)
        def suite_files(suite)
          files = Array(suite.loads).map { |path| File.expand_path(path) }
          [files, suite.path && AdapterSelection.call(suite.path, files)]
        end

        # @return [Object, StandardError] the booted runtime, or the error its boot raised
        def boot_or_failure(engine, files, adapters)
          engine == :kernel ? boot_kernel(files, adapters) : boot_and_guard(files, adapters)
        rescue StandardError => e
          e
        end

        # Boots the suite's files on the Rust kernel, built for the feature its first bluebook's
        # directory names, after the same Memory-only check the in-process boot makes.
        #
        # @param files [Array<String>] absolute paths to the files to boot
        # @param adapters [Array<String>, nil] the `.adapter` files `AdapterSelection` chose
        # @return [Runtime::KernelDispatcher] the connected kernel dispatcher
        # @raise [Malformed] if any aggregate is bound to a non-Memory adapter
        def boot_kernel(files, adapters)
          require_relative "../../rust_build/kernel_engine"
          engine = RustBuild::KernelEngine
          registry = engine.describe_files(files, adapters: adapters)
          guard_registry!(registry)
          bluebook = files.find { |file| file.end_with?(".bluebook") } || files.first
          engine.connect(registry, engine.feature_of(File.dirname(bluebook)))
        end

        # Each file with its mtime, so an edited file boots fresh.
        def boot_key(files) = files.map { |file| [file, File.exist?(file) ? File.mtime(file).to_f : nil] }

        # Refuses at boot when any aggregate binds to a non-Memory adapter —
        # `reset_runtime_state!` only resets Memory's own per-instance store.
        #
        # @param files [Array<String>] absolute paths to the bluebook/hecksagon/world
        #   files to boot
        # @param adapters [Array<String>, nil] the `.adapter` files `AdapterSelection` chose, or
        #   nil for a suite with no file of its own
        # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted,
        #   Memory-only-guarded runtime
        # @raise [Malformed] if any aggregate is bound to a non-Memory adapter
        def boot_and_guard(files, adapters = nil)
          runtime = Hecks.boot_files(files, install_driving: false, adapters: adapters)
          guard_memory_only!(runtime)
          runtime
        end

        # Refuses a runtime where any aggregate is bound to anything other than the
        # default (Memory) adapter, so tests can never leak state or touch a real store.
        #
        # @param runtime [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted
        #   runtime to check
        # @return [void]
        # @raise [Malformed] if any aggregate is bound to a non-Memory adapter
        def guard_memory_only!(runtime) = guard_registry!(runtime.registry)

        # @param registry [Runtime::Registry] the declarations a suite boots
        # @return [void]
        # @raise [Malformed] if any aggregate is bound to a non-Memory adapter
        def guard_registry!(registry)
          registry.bluebooks.each_value do |bluebook|
            bluebook.aggregates.each do |aggregate|
              bind = Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, aggregate)
              next if in_memory?(registry, bluebook, bind)

              raise Malformed, non_memory_message(bluebook, aggregate, bind)
            end
          end
        end

        # Adapters that are a plain Memory store while the setting they read files from is unset or
        # `None`, which a suite's Memory world, or no world at all, leaves.
        FILE_SETTING = { "DecisionFiles" => :directory }.freeze
        private_constant :FILE_SETTING

        # @return [Boolean] whether the bind is the default Memory adapter, or an adapter that
        #   reads no files in this boot
        def in_memory?(registry, bluebook, bind)
          return true if bind.adapter == Ports::Persistence::DEFAULT_ADAPTER

          key = FILE_SETTING[bind.adapter.to_s]
          !key.nil? && reads_no_files?(registry.binding_settings(bluebook.name, Ports::Persistence::VERB, bind.adapter), key)
        end

        # @return [Boolean] whether the setting that names the files is unset or `None`
        def reads_no_files?(settings, key)
          setting = settings.transform_keys(&:to_sym)[key]
          setting.nil? || setting.to_s.casecmp?("None")
        end

        # @return [String] why a behaviors suite refuses an aggregate that is not bound to Memory
        def non_memory_message(bluebook, aggregate, bind)
          "#{bluebook.name}::#{aggregate.hecks_name} is persisted_by " \
            "#{bind.adapter.inspect}, not #{Ports::Persistence::DEFAULT_ADAPTER.inspect} — " \
            "a behaviors suite's `loads` must resolve every aggregate to an in-memory " \
            "binding, or tests leak state into each other and write to a real database. " \
            "Load a Memory-bound sibling hecksagon instead of the domain's real one — see " \
            "examples/pizzas/bluebook/pizzas.behaviors's own `loads` comment for the pattern."
        end
      end
    end
  end
end
