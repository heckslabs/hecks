# Hecks::BluebookModel::Behavior::Saga
#
# Intermediate representation of a saga (process manager) for long-running
# stateful business processes with compensation. A saga has a name, an
# ordered list of steps, an optional timeout, and an optional on_timeout
# handler command.
#
# Part of the BluebookModel IR layer. Built by SagaBuilder in the DSL,
# consumed by SagaRunner at runtime to execute the step sequence with
# compensation on failure.
#
#   saga = Saga.new(
#     name: "OrderFulfillment",
#     steps: [step1, step2],
#     timeout: "48h",
#     on_timeout: "CancelOrder"
#   )
#   saga.timed?  # => true
#
module Hecks
  module BluebookModel
    module Behavior
      class Saga
        # @return [String] PascalCase saga name
        attr_reader :name

        # @return [Array<SagaStep>] ordered list of steps
        attr_reader :steps

        # @return [String, nil] timeout duration string (e.g. "48h", "30m")
        attr_reader :timeout

        # @return [String, nil] command to dispatch on timeout
        attr_reader :on_timeout

        # Creates a new Saga IR node.
        #
        # @param name [String] the saga name
        # @param steps [Array<SagaStep>] ordered steps
        # @param timeout [String, nil] timeout duration
        # @param on_timeout [String, nil] timeout handler command
        def initialize(name:, steps: [], timeout: nil, on_timeout: nil)
          @name = name.to_s
          @steps = steps
          @timeout = timeout
          @on_timeout = on_timeout&.to_s
        end

        # Whether this saga has a timeout configured.
        #
        # @return [Boolean]
        def timed?
          !@timeout.nil?
        end
      end
    end
  end
end
