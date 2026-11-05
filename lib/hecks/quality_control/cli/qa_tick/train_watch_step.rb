# frozen_string_literal: true

require_relative "../qa_train_watch"

module Hecks
  module QualityControlCli
    class QaTick
      # The tick's train watch: asks each queued push-train boarding whether its pull request has
      # merged, and records the push when it has. It runs after the event pump, on every tick.
      module TrainWatchStep
        private

        # @return [Array<Step>] the watch step when the `train_watch` dial is on (on by default)
        def train_watch_steps
          dial(:TRAIN_WATCH, true) ? [guarded("train_watch") { run_train_watch }] : []
        end

        # @return [Array(String, Integer)] the watch's output and its exit status
        def run_train_watch
          banner "hecks quality_control train.watch!"
          output, exit_code = run_step(->(argv) { QaTrainWatch.call(argv, root: @root) })
          puts output
          [output, exit_code]
        end
      end
    end
  end
end
