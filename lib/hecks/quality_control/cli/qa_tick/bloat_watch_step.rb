# frozen_string_literal: true

require_relative "../qa_bloat_watch"

module Hecks
  module QualityControlCli
    class QaTick
      # The tick's bloat watch, once per tick: `Dispatch.Watch` with confirm stops the session of a
      # bloated started Work row and yields the row to the plan, with the rule as the reason.
      module BloatWatchStep
        private

        # @return [Array<Step>] the watch's step when the `bloat_watch` dial is on, else none
        def bloat_watch_steps
          dial(:BLOAT_WATCH, false) ? [guarded("bloat_watch") { run_bloat_watch }] : []
        end

        # @return [Array(String, Integer)] the watch's output and its exit status
        def run_bloat_watch
          banner "hecks Dispatch.watch! confirm.value=true"
          output, exit_code = run_step(->(argv) { QaBloatWatch.call(argv, root: @root) })
          puts output
          [output, exit_code]
        end
      end
    end
  end
end
