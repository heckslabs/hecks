# Hecks::DSL::TestBuilder
#
# Captures the body of one `test "..." do ... end` block. Surface:
#
#   tests   <CommandName>, on: <Aggregate>, kind: :command|:query
#   setup   <CommandName>, **args        # zero or more arrange-phase calls
#   input   **args                       # the act-phase command/query args
#   expect  **assertions                 # final-state / result assertions
#
# `tests` is required. `kind` defaults to :command. `setup`, `input`,
# and `expect` are all optional but most tests have at least input + expect.
#
module Hecks
  module DSL
    class TestBuilder
      def initialize(description)
        @description   = description
        @tests_command = nil
        @on_aggregate  = nil
        @kind          = :command
        @setups        = []
        @input         = {}
        @expect        = {}
      end

      def tests(command, on:, kind: :command)
        @tests_command = command
        @on_aggregate  = on
        @kind          = kind
      end

      def setup(command, **args)
        @setups << BluebookModel::Structure::TestSetup.new(
          command: command, args: args,
        )
      end

      def input(**args)
        @input = args
      end

      def expect(**assertions)
        @expect = assertions
      end

      def build
        BluebookModel::Structure::Test.new(
          description:   @description,
          tests_command: @tests_command,
          on_aggregate:  @on_aggregate,
          kind:          @kind,
          setups:        @setups,
          input:         @input,
          expect:        @expect,
        )
      end
    end
  end
end
