require_relative "../ir"
require_relative "../../runtime/loader"
require_relative "../../runtime/errors"
require_relative "../../ports/persistence/binding_policy"
require_relative "adapter_selection"

module Hecks
  module Behaviors
    module Expectations
      # Boots the runtime a behaviors suite's `loads` names, once per set of files, and refuses
      # one that binds an aggregate to anything but Memory. Extended onto `Expectations`.
      module Boot
        # Cached per suite, keyed by `loads`' file paths and mtimes, so a boot is
        # reused across tests but an edited bluebook boots fresh on the next one.
        # Mutated in place (`RUNTIMES[key] ||= boot_and_guard(files)`).
        RUNTIMES      = {}
        RUNTIMES_LOCK = Mutex.new
        private_constant :RUNTIMES, :RUNTIMES_LOCK

        # Boots (or reuses the cached boot of) the runtime a suite's `loads` names.
        #
        # @param suite [Behaviors::BehaviorsSuite] the suite whose `loads` files boot
        #   the runtime
        # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the cached or
        #   freshly booted, Memory-only-guarded runtime
        # @raise [Malformed] if any aggregate the suite boots is not bound to the
        #   default (Memory) adapter
        def runtime_for(suite)
          files    = Array(suite.loads).map { |path| File.expand_path(path) }
          adapters = suite.path && AdapterSelection.call(suite.path, files)
          key      = boot_key(files + Array(adapters))

          RUNTIMES_LOCK.synchronize do
            RUNTIMES[key] ||= boot_and_guard(files, adapters)
          end
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
        def guard_memory_only!(runtime)
          registry = runtime.registry
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
