# Hecks::DomainModel::Behavior::SagaStep
#
# Intermediate representation of a single step within a saga. Each step
# has a command to execute, optional success/failure event names, and an
# optional compensation command to reverse the step on failure.
#
# Part of the DomainModel IR layer. Built by SagaStepBuilder in the DSL,
# consumed by SagaRunner at runtime.
#
#   step = SagaStep.new(
#     command: "ReserveInventory",
#     on_success: "InventoryReserved",
#     on_failure: "ReservationFailed",
#     compensate: "ReleaseInventory"
#   )
#   step.compensatable?  # => true
#
module Hecks
  module DomainModel
    module Behavior
      class SagaStep
        # @return [String] PascalCase command name to dispatch
        attr_reader :command

        # @return [String, nil] event name emitted on success
        attr_reader :on_success

        # @return [String, nil] event name emitted on failure
        attr_reader :on_failure

        # @return [String, nil] compensation command to dispatch on rollback
        attr_reader :compensate

        # Creates a new SagaStep IR node.
        #
        # @param command [String] the command name to execute
        # @param on_success [String, nil] event name for success
        # @param on_failure [String, nil] event name for failure
        # @param compensate [String, nil] compensation command name
        def initialize(command:, on_success: nil, on_failure: nil, compensate: nil)
          @command = command.to_s
          @on_success = on_success&.to_s
          @on_failure = on_failure&.to_s
          @compensate = compensate&.to_s
        end

        # Whether this step has a compensation command defined.
        #
        # @return [Boolean]
        def compensatable?
          !@compensate.nil? && !@compensate.empty?
        end
      end
    end
  end
end
