# frozen_string_literal: true

require_relative "kernel_runtime"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Boots the runtime a sequence is built against, on the engine the generator was given:
      # `:ruby`, the in-process runtime, or `:kernel`, the Rust kernel over the host protocol
      # (ADR 0188 step 9, slice 3 of docs/plans/simulation-tests.md). The kernel never falls back
      # to Ruby, and its process is ended however the generation ends.
      module Drive
        # The engines a generator can be built through.
        ENGINES = %i[ruby kernel].freeze

        module_function

        # @param engine [Symbol] one of `ENGINES`
        # @param copy [String] the isolated copy of the domain to boot
        # @param domain_path [String] the original domain, whose generated IR greets the kernel
        # @param binary [#call] answers the kernel binary; called only for `:kernel`
        # @yieldparam runtime [Object] the booted runtime
        # @return [Object] the block's value
        def open(engine, copy, domain_path, binary:, &)
          return yield(Hecks.boot(copy, environment: nil)) if engine == :ruby

          kernel(KernelRuntime.connect(copy, domain_path, binary.call), &)
        end

        # Yields the kernel runtime and closes it, even when the block raises.
        #
        # @param runtime [#close] the connected kernel runtime
        # @return [Object] the block's value
        def kernel(runtime)
          yield runtime
        ensure
          runtime.close
        end
      end
    end
  end
end
