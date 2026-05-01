module Hecks
  module BluebookModel
    module Behavior

      # Hecks::BluebookModel::Behavior::Condition
      #
      # A named assertion on a command -- either a precondition (checked before
      # execution against the current aggregate state) or a postcondition
      # (checked after execution by comparing before/after state).
      #
      # Precondition blocks receive the current aggregate as a single argument
      # and must return truthy for the command to proceed. Postcondition blocks
      # receive two arguments (the aggregate state before and after execution)
      # and must return truthy for the command result to be accepted.
      #
      # Part of the BluebookModel IR layer. Built by CommandBuilder's +precondition+
      # and +postcondition+ DSL methods, stored on Command IR nodes, and evaluated
      # at runtime by the CommandRunner.
      #
      #   pre  = Condition.new(message: "sufficient funds", block: ->(agg) { agg.balance >= 100 })
      #   post = Condition.new(message: "balance decreased", block: ->(before, after) { after.balance < before.balance })
      #
      class Condition
        # @return [String] human-readable description of what this condition asserts,
        #   used in error messages when the condition fails
        # @return [Proc] the callable that evaluates the condition. For preconditions,
        #   receives (aggregate). For postconditions, receives (before_state, after_state).
        attr_reader :message, :block

        # Creates a new Condition IR node.
        #
        # @param message [String] human-readable assertion description, shown in
        #   validation error messages when the condition is not satisfied
        # @param block [Proc] callable that evaluates the condition. Must return
        #   truthy for the condition to pass. Arity depends on usage context:
        #   preconditions receive 1 arg (aggregate), postconditions receive 2
        #   (before_state, after_state)
        # @return [Condition]
        def initialize(message:, block:)
          @message = message
          @block = block
        end
      end
    end
  end
end
