module Hecks
  module Bluebook
    # Whether the declarations being read are lent: another checkout's local files, loaded by a
    # worktree that keeps none of its own. A bind read while lent is marked, so the wiring gate
    # can leave out one whose aggregate the borrower's code does not declare.
    module Lent
      KEY = :hecks_lent_declarations

      module_function

      # Runs a block with every bind it reads marked as lent, or not.
      #
      # @param lent [Boolean] whether the files read inside are another checkout's
      # @return [Object] the block's value
      def during(lent)
        held = Thread.current[KEY]
        Thread.current[KEY] = lent
        yield
      ensure
        Thread.current[KEY] = held
      end

      # @return [Boolean] whether the declarations being read now are lent
      def now? = Thread.current[KEY] == true
    end
  end
end
