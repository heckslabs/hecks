# frozen_string_literal: true

require_relative "../qa_push_nudge"

module Hecks
  module QualityControlCli
    class QaTick
      # The tick's push check, once per tick: `PushNudge.Check` files, revises or finishes the one
      # `push-due` Work row from refs git already holds. It fetches, pushes and merges nothing.
      module PushNudgeStep
        private

        # @return [Array<Step>] the check's step when the `push_nudge` dial is on, else none
        def push_nudge_steps
          dial(:PUSH_NUDGE, false) ? [guarded("push_nudge") { run_push_nudge }] : []
        end

        # @return [Array(String, Integer)] the check's output and its exit status
        def run_push_nudge
          banner "hecks quality_control push_nudge.check!"
          output, exit_code = run_step(->(argv) { QaPushNudge.call(argv, root: @root) })
          puts output
          [output, exit_code]
        end
      end
    end
  end
end
