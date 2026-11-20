# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # Tells which open calls for help the owner is shown, one line each. The adapter only
      # measures (is the help the owner's, how many minutes has the block stood); the `Help owner`
      # rows of the bluebook decide, against the `help_unanswered_minutes` setting. Nothing is
      # sent anywhere: the lines are read by the board's Waiting-on-you panel and nothing else.
      module HelpQueue
        STAGE = "Help owner"
        SHOWN = "owner"
        HOUR = 60
        DAY = 1440
        UNREAD = "the calls for help could not be read"

        module_function

        # @param calls [Array<Hash>, Object] the open calls for help, or `{unknown:}`
        # @param now [Time] the time the ages are measured against
        # @return [Hash] `help`: the lines the owner is shown, the oldest block first, and
        #   `help_unknown`: the reason when the calls could not be read
        def reading(calls, now)
          return { help: lines(calls, now) } if calls.is_a?(Array)

          { help: [], help_unknown: calls.is_a?(Hash) ? calls[:unknown].to_s : UNREAD }
        end

        # @param calls [Array<Hash>] the open calls: `help`, `opened_at`, `needs` and `role`
        # @param now [Time] the time the ages are measured against
        # @return [Array<Hash>] one row per call the owner is shown: its `help` key, the `line`
        #   (`needs you: <needs>, <age>`), its age in `minutes` and `opened_at`
        def lines(calls, now)
          calls.filter_map { |call| line(call, minutes(call, now)) }
        end

        def line(call, minutes)
          return unless Rules.verdict(STAGE, owner_role: call[:role] == SHOWN ? 1 : 0, minutes: minutes) == SHOWN

          { help: call[:help], line: "needs you: #{call[:needs]}, #{age(minutes)}", minutes: minutes,
            opened_at: call[:opened_at] }
        end

        # The whole minutes the block has stood (none for a time still ahead), nil when its opening
        # time cannot be read.
        def minutes(call, now)
          [((now - Time.parse(call[:opened_at].to_s)) / 60).floor, 0].max
        rescue ArgumentError
          nil
        end

        def age(minutes)
          return "age unknown" unless minutes
          return "#{minutes}m" if minutes < HOUR

          minutes < DAY ? "#{minutes / HOUR}h" : "#{minutes / DAY}d"
        end
      end
    end
  end
end
