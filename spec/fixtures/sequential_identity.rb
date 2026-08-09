module Hecksagain
  module Adapters
    # The deterministic `identity_generation` fulfillment — a plain
    # incrementing counter, not a real UUID, so a spec or a fuzz run
    # can assert on the exact id a creating command gets rather than
    # merely "some string." `reset!` exists because this module's
    # state is class-level, not per-boot the way `Memory`'s own
    # `@records` is — a spec that wants a fresh count starting at 1
    # calls it explicitly, the same way a spec resets any other piece
    # of shared test state.
    module SequentialIdentity
      module_function

      def uuid
        @count = (@count || 0) + 1
        @count.to_s
      end

      def reset! = @count = 0
    end
  end
end
