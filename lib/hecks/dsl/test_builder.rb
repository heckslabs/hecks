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
        @description    = description
        @tests_command  = nil
        @on_aggregate   = nil
        @kind           = :command
        @setups         = []
        @input          = {}
        @expect         = {}
        @events_include = []
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

      # Assert the act-phase event log is a superset of these names.
      #
      #   then_events_include "BodyPulse", "FatigueAccumulated"
      #
      # Complements strict-order `expect emits:` — use this for
      # cross-bluebook cascades where relative event ordering is a
      # drain-order detail, not a semantic contract. Append-only so
      # multiple lines accumulate; order in the list is irrelevant to
      # the assertion but preserved for readable diagnostics.
      #
      # No consumer in this commit; the IR field is populated so the
      # runtime assertion logic (commit 7 of the plan) can read it.
      def then_events_include(*event_names)
        @events_include.concat(event_names.map(&:to_s))
      end

      def build
        BluebookModel::Structure::Test.new(
          description:    @description,
          tests_command:  @tests_command,
          on_aggregate:   @on_aggregate,
          kind:           @kind,
          setups:         @setups,
          input:          @input,
          expect:         @expect,
          events_include: @events_include,
        )
      end
    end
  end
end
