module Hecks
  module Runtime
    # The one place the runtime answers a default when a read raises, so a deliberate guard is
    # named at its call site and `Hecks/SwallowedRescue` can refuse every other silent swallow.
    #
    # BestEffort.call(false) { adapter_class.tenant_capable? }  # => false when the lookup raises
    module BestEffort
      module_function

      # Runs the block and answers its value, or `default` when it raises a StandardError.
      #
      # @param default [Object] what to answer when the block raises
      # @yield the read that may raise
      # @return [Object] the block's value, or `default`
      def call(default)
        yield
      rescue StandardError
        default
      end
    end
  end
end
