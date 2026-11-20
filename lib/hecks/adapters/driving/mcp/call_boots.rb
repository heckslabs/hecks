module Hecks
  module Adapters
    module Driving
      module Mcp
        # The kernel dispatchers an unrestricted server boots for one call, closed when the call
        # answers. An unrestricted server boots its domain afresh on every call; on the kernel
        # engine each boot holds a kernel process, so none is left running past the call that made
        # it, whether the call answered or raised. A Ruby engine boot holds no process and is not
        # kept. A boot outside a call (no `closing_call_boots` around it) is its caller's to close.
        module CallBoots
          # The thread-local list of this call's kernel dispatchers.
          KEY = :mcp_call_boots

          # Boots `path` for this call, keeping a kernel dispatcher to close when the call ends.
          #
          # @param path [String] the confined domain directory
          # @return [Runtime::Dispatcher, Runtime::KernelDispatcher] the booted domain
          def call_boot(path)
            runtime = Hecks.boot(path, install_driving: false)
            Thread.current[KEY]&.push(runtime) if kernel?(runtime)
            runtime
          end

          # Runs the block as one call, closing every kernel dispatcher it booted when it ends.
          #
          # @return [Object] the block's value
          def closing_call_boots
            outer = Thread.current[KEY]
            Thread.current[KEY] = []
            yield
          ensure
            Thread.current[KEY].each(&:close)
            Thread.current[KEY] = outer
          end

          # @param runtime [Object] a booted dispatcher
          # @return [Boolean] whether it runs on the kernel engine
          def kernel?(runtime)
            defined?(Runtime::KernelDispatcher) ? runtime.is_a?(Runtime::KernelDispatcher) : false
          end
        end
      end
    end
  end
end
