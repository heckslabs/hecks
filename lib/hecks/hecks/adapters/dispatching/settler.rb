# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class Dispatching
      # Settles the started work items whose sessions have ended: asks each running session how it
      # is, then finishes the work item whose branch landed since it started and yields any other,
      # with the condition as the reason. A session still working is left alone.
      class Settler
        # @param work_items [WorkItems] where the started work items and the runs are read
        # @param launcher [Launcher] runs the commands that check, finish and yield
        # @param grace [Integer] seconds after its start that a run's session is read as unknown
        # @param clock [#call] answers the time, for the grace
        # @param rule [Hash] `landed:` answers the commit a work item's branch landed as since it
        #   started, or nil (none given: no landing is asked for); `gone:` is the world's rule
        #   (`#run_gone_minutes`, `#claude_missing?`): while `claude` cannot be run, a started run
        #   older than its minutes is asked to retire; `sessions:` (`#quiet?(session)`) answers
        #   whether `claude` lists a session stopped or not at all: with it, an old started run
        #   whose session is quiet is asked to retire on the normal path too
        def initialize(work_items, launcher, grace: 0, clock: -> { Time.now.utc }, **rule)
          @gone = rule[:gone]
          @work_items = work_items
          @launcher = launcher
          @grace = grace
          @clock = clock
          @landed = rule[:landed]
          @sessions = rule[:sessions]
        end

        # @return [Array<String>] one line for each work item settled, empty when none was
        def call
          @launcher.check_all unless checkable.empty?
          retire_gone
          ended.filter_map { |key, run| settle(key, run[:condition]) }
        end

        private

        # With `claude` out of reach nothing lists a session, so a run started longer ago than the
        # world's minutes is asked to retire; `AgentRun.Retire` closes it only when the world's rule
        # finds no process, commit or change, and keeps it otherwise.
        def retire_gone
          return unless @gone

          missing = @gone.claude_missing?
          checkable.each { |key, run| @launcher.retire(key) if old?(run) && (missing || quiet?(run)) }
        end

        # A working or waiting session is never asked about, so no launcher boot is spent on it.
        def quiet?(run)
          @sessions ? @sessions.quiet?(run[:session].to_s) : false
        end

        def old?(run)
          @clock.call - Time.parse(run[:started_at].to_s) > @gone.run_gone_minutes * 60
        rescue ArgumentError
          false
        end

        # The runs are read again before a Work item is yielded, so only a run still finished ends
        # its item. An answer's own stop never finishes a run (`RecordTheEndedSession` leaves a
        # `resuming` run alone), so a session an answer woke keeps its run started.
        #
        # A landed branch and a submitted branch finish their Work item by their own reactions. When
        # that reaction is lost the item is still started here, so a landing since its start
        # refuses the yield and finishes it instead, however the session ended. An item with no
        # landing that ended `done` goes back to the plan with a finding.
        def settle(key, condition)
          return unless @work_items.runs.dig(key, :status) == "finished"

          sha = @landed&.call(key)
          return finish_landed(key, sha) if sha

          yield_ended(key, condition)
        end

        def finish_landed(key, sha) = "#{@launcher.finish(key)}: landed as #{sha[0, 9]}, finishing instead"

        def yield_ended(key, condition)
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
