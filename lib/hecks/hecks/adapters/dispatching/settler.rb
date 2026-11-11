# frozen_string_literal: true

require "time"

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
        # @param grace [Integer] seconds after its start that a run's session is read as unknown
        # @param clock [#call] answers the time, for the grace
        def initialize(work_items, launcher, grace: 0, clock: -> { Time.now.utc })
          @work_items = work_items
          @launcher = launcher
          @grace = grace
          @clock = clock
        end

        # @return [Array<String>] one line for each work item settled, empty when none was
        def call
          @launcher.check_all unless checkable.empty?
          ended.filter_map { |key, run| settle(key, run[:condition]) }
        end

        private

        # The runs are read again before a Work item is yielded, so only a run still finished ends
        # its item. An answer's own stop never finishes a run (`RecordTheEndedSession` leaves a
        # `resuming` run alone), so a session an answer woke keeps its run started.
        #
        # A landed branch and a submitted branch finish their Work item themselves, so an item still
        # started when its session ended `done` landed nothing: it goes back to the plan with a
        # finding, never to `finished`.
        def settle(key, condition)
          return unless @work_items.runs.dig(key, :status) == "finished"

          reason = condition == "done" ? "its session ended done with no landing or submission" : "its session ended #{condition}"
          line = @launcher.yield_back(item_of(key), reason)
          condition == "done" ? "#{line}\n#{@launcher.report_unlanded(key)}" : line
        end

        # The started work item itself, which carries how many times it has yielded, so a session
        # that fails again and again backs off longer each time.
        def item_of(key) = started.find { |item| item.key == key } || key

        def started = (@started ||= @work_items.started)

        def checkable = mine.select { |_key, run| run[:status] == "started" }

        # A clock guard only: a run younger than the grace has not been read long enough to say
        # how its session ended, so it is left alone. A run with no recorded start counts as old.
        def ended = mine.select { |_key, run| run[:status] == "finished" && !young?(run) }

        def young?(run)
          @clock.call - Time.parse(run[:started_at].to_s) < @grace
        rescue ArgumentError
          false
        end

        def mine
          @work_items.runs.slice(*started.map(&:key))
        end
      end
    end
  end
end
