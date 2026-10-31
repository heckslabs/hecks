# frozen_string_literal: true

require "hecks/tools/gate"

module Hecks
  module QualityControlCli
    class QaMainGate
      # Runs the quick gate's checks in a directory, all at once, and says which passed. The checks are
      # the `GateStage` rows of the Vocabulary bluebook, so a red check is reported with the output it
      # printed, the same way `hecks gate quick` reports one.
      module GateRun
        # One check of the quick gate after it ran.
        #
        # @!attribute [r] id
        #   @return [String] the check's name in the Vocabulary bluebook, such as `rubocop`
        # @!attribute [r] title
        #   @return [String] what the check is
        # @!attribute [r] output
        #   @return [String] everything the check printed
        # @!attribute [r] passed
        #   @return [Boolean] whether it exited 0
        Result = Struct.new(:id, :title, :output, :passed)

        # Stands in for the gate's progress lines, which go to standard error of a person's terminal.
        class Quiet
          # @return [nil]
          def start(_id) = nil

          # @return [nil]
          def finish(*) = nil
        end

        module_function

        # @param dir [String] the checkout the checks run in
        # @return [Array<Result>] every quick-gate check, in the stage's order
        def run(dir)
          stage = Hecks::Tools::Gate.stages.fetch("quick")
          checks = stage.fetch("checks")
          answers = Hecks::Tools::Gate.run_all(stage, checks, dir, Quiet.new)
          checks.map { |check| result(check, answers.fetch(check.fetch("id"))) }
        end

        # @return [Result]
        def result(check, answer)
          output, passed = answer
          Result.new(check.fetch("id"), check.fetch("title"), output, passed)
        end
      end
    end
  end
end
