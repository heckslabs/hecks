# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Settles the started rows whose sessions have ended: asks each running session how it is,
      # then
      # finishes the row of one that ended `done` and yields the row of one that ended any other
      # way,
      # with the condition as the reason. A session still working is left alone.
      class Settler
        # @param rows [Rows] where the started rows and the runs are read
        # @param launcher [Launcher] runs the commands that check, finish and yield
        def initialize(rows, launcher)
          @rows = rows
          @launcher = launcher
        end

        # @return [Array<String>] one line for each row settled, empty when none was
        def call
          checkable.each_key { |key| @launcher.check(key) }
          ended.map { |key, run| settle(key, run[:condition]) }
        end

        private

        def settle(key, condition)
          condition == "done" ? @launcher.finish(key) : @launcher.yield_back(key, "its session ended #{condition}")
        end

        def checkable = mine.select { |_key, run| run[:status] == "started" }

        def ended = mine.select { |_key, run| run[:status] == "finished" }

        def mine
          started = @rows.started.map(&:key)
          @rows.runs.slice(*started)
        end
      end
    end
  end
end
