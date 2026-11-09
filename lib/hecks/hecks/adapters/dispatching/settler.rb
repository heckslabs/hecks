# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Settles the started work items whose sessions have ended: asks each running session how it
      # is,
      # then
      # finishes the work item of one that ended `done` and yields the work item of one that ended
      # any other
      # way,
      # with the condition as the reason. A session still working is left alone.
      class Settler
        # @param work items [WorkItems] where the started work items and the runs are read
        # @param launcher [Launcher] runs the commands that check, finish and yield
        def initialize(work_items, launcher)
          @work_items = work_items
          @launcher = launcher
        end

        # @return [Array<String>] one line for each work item settled, empty when none was
        def call
          @launcher.check_all unless checkable.empty?
          ended.map { |key, run| settle(key, run[:condition]) }
        end

        private

        def settle(key, condition)
          return @launcher.finish(key) if condition == "done"

          @launcher.yield_back(item_of(key), "its session ended #{condition}")
        end

        # The started work item itself, which carries how many times it has yielded, so a session
        # that fails again and again backs off longer each time.
        def item_of(key) = started.find { |item| item.key == key } || key

        def started = (@started ||= @work_items.started)

        def checkable = mine.select { |_key, run| run[:status] == "started" }

        def ended = mine.select { |_key, run| run[:status] == "finished" }

        def mine
          @work_items.runs.slice(*started.map(&:key))
        end
      end
    end
  end
end
