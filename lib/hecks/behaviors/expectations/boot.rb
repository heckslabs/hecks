require_relative "../ir"
require_relative "../../runtime/loader"
require_relative "../../runtime/errors"
require_relative "../../ports/persistence/binding_policy"

module Hecks
  module Behaviors
    module Expectations
      # Boots the runtime a behaviors suite's `loads` names, once per set of files, and refuses
      # one that binds an aggregate to anything but Memory. Extended onto `Expectations`.
      module Boot
        # Cached per suite, keyed by `loads`' file paths and mtimes, so a boot is
        # reused across tests but an edited bluebook boots fresh on the next one.
        # Mutated in place (`RUNTIMES[key] ||= boot_and_guard(files)`).
        # rubocop:disable-next Style/MutableConstant
        RUNTIMES      = {}
        RUNTIMES_LOCK = Mutex.new
        private_constant :RUNTIMES, :RUNTIMES_LOCK

        # Boots (or reuses the cached boot of) the runtime a suite's `loads` names.
        #
        # @param suite [Behaviors::BehaviorsSuite] the suite whose `loads` files boot
        #   the runtime
        # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the cached or
        #   freshly booted, Memory-only-guarded runtime
        # @raise [Malformed] if any aggregate the suite boots is not bound to the
        #   default (Memory) adapter
        def runtime_for(suite)
          files = Array(suite.loads).map { |path| File.expand_path(path) }
          key   = files.map { |file| [file, File.exist?(file) ? File.mtime(file).to_f : nil] }

          RUNTIMES_LOCK.synchronize do
            RUNTIMES[key] ||= boot_and_guard(files)
          end
        end

        # Refuses at boot when any aggregate binds to a non-Memory adapter —
        # `reset_runtime_state!` only resets Memory's own per-instance store.
        #
        # @param files [Array<String>] absolute paths to the bluebook/hecksagon/world
        #   files to boot
        # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted,
        #   Memory-only-guarded runtime
        # @raise [Malformed] if any aggregate is bound to a non-Memory adapter
        def boot_and_guard(files)
          runtime = Hecks::Runtime::Loader.boot_files(files, install_driving: false)
          guard_memory_only!(runtime)
          runtime
        end

        # Refuses a runtime where any aggregate is bound to anything other than the
        # default (Memory) adapter, so tests can never leak state or touch a real store.
        #
        # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
        #   runtime to check
        # @return [void]
        # @raise [Malformed] if any aggregate is bound to a non-Memory adapter
        def guard_memory_only!(runtime)
          runtime.registry.bluebooks.each_value do |bluebook|
            bluebook.aggregates.each do |aggregate|
              bind = Ports::Persistence::BindingPolicy.resolve(runtime.registry, bluebook.name, aggregate)
              next if bind.adapter == Ports::Persistence::DEFAULT_ADAPTER

              raise Malformed, non_memory_message(bluebook, aggregate, bind)
            end
          end
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
