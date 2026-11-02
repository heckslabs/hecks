# frozen_string_literal: true

require_relative "../qa_red_main_watch"

module Hecks
  module QualityControlCli
    class QaTick
      # The tick's CI-on-main step, once per tick, beside the push check: `QaRedMainWatch` keeps one
      # open `red-main-<run id>` Work row while the latest CI run on main is red and finishes it
      # when a later run passes. A quiesced tick skips it like every other step.
      module RedMainWatchStep
        private

        # @return [Array<Step>] the watch's step unless the `red_main_watch` dial is off
        def red_main_watch_steps
          dial(:RED_MAIN_WATCH, true) ? [guarded("red_main_watch") { run_red_main_watch }] : []
        end

        # @return [Array(String, Integer)] the watch's output and its exit status
        def run_red_main_watch
          banner "hecks quality_control red_main_watch"
          output, exit_code = run_step(->(argv) { QaRedMainWatch.call(argv, root: @root) })
          puts output
          [output, exit_code]
        end
      end
    end
  end
end
