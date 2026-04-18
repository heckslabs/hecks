# Hecks::BluebookModel::Structure::Test
#
# A single behavioral test inside a TestSuite. Names the command-or-query
# under test, the aggregate it lives on, optional arrange-phase setups,
# the input arguments to dispatch, and the assertions to verify.
#
# Test kinds:
#   :command — dispatch input as a command, assert against final aggregate state
#   :query   — dispatch input as a query, assert against the result
#
# Reserved expect keys (interpreted by the runner; everything else
# matches against an aggregate attribute by name):
#   count           — assert query result count
#   refused         — assert command was rejected with this given-clause message
#   <attr>_size     — assert list attribute has this size
#
#   test = Test.new(
#     description: "CreatePizza sets name",
#     tests_command: "CreatePizza",
#     on_aggregate: "Pizza",
#     kind: :command,
#     setups: [],
#     input:  { name: "Margherita", description: "Classic" },
#     expect: { name: "Margherita" },
#   )
#
module Hecks
  module BluebookModel
    module Structure
      class Test
        attr_reader :description, :tests_command, :on_aggregate, :kind,
                    :setups, :input, :expect

        def initialize(description:, tests_command:, on_aggregate:, kind: :command,
                       setups: [], input: {}, expect: {})
          @description   = description
          @tests_command = tests_command
          @on_aggregate  = on_aggregate
          @kind          = kind.to_sym
          @setups        = setups
          @input         = input
          @expect        = expect
        end

        def ==(other)
          other.is_a?(Test) &&
            description == other.description &&
            tests_command == other.tests_command &&
            on_aggregate == other.on_aggregate &&
            kind == other.kind &&
            setups == other.setups &&
            input == other.input &&
            expect == other.expect
        end
        alias eql? ==

        def hash
          [description, tests_command, on_aggregate, kind, setups, input, expect].hash
        end
      end

      # A single arrange-phase command call inside a Test.
      class TestSetup
        attr_reader :command, :args

        def initialize(command:, args: {})
          @command = command
          @args    = args
        end

        def ==(other)
          other.is_a?(TestSetup) && command == other.command && args == other.args
        end
        alias eql? ==

        def hash
          [command, args].hash
        end
      end
    end
  end
end
