# frozen_string_literal: true

require_relative "../pipeline_stages/panel"

module Hecks
  module Adapters
    module PipelineBoard
      # The text panel `PipelineBoard.snapshot` prints, drawn by the running board from the state
      # it already holds and kept for a few seconds, so a terminal that asks again and again costs
      # one drawing per window and one read of the open train pull requests.
      #
      # A drawing is kept by the state's `version` and the panel's width, colour and limit: a new
      # version draws again at once. The held state's age (`stale_seconds`) is part of the
      # drawing, so a kept panel may show an age up to the window's seconds old.
      class PanelCache
        # Seconds a drawing, and the train pull requests it shows, are kept.
        SECONDS = 5

        # @param state [#call] answers the board's held state
        # @param train_prs [#call] answers the open train pull requests
        # @param seconds [Numeric] how long a drawing is kept
        # @param now [#call] answers a monotonic clock in seconds
        def initialize(state:, train_prs:, seconds: SECONDS, now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @state = state
          @train_prs = train_prs
          @seconds = seconds
          @now = now
          @drawn = {}
          @lock = Mutex.new
        end

        # @param width [Integer, nil] the panel's columns
        # @param colour [Boolean] whether rows are coloured by their state
        # @param limit [Integer, nil] how many planned Work items and finished sessions to list
        # @return [String] the panel, kept or drawn now
        def panel(width: nil, colour: false, limit: nil)
          state = @state.call
          key = [state[:version], width, colour, limit]
          @lock.synchronize { kept(key) || draw(key, state) }
        end

        private

        def kept(key)
          found = @drawn[key]
          found[:text] if found && fresh?(found[:at])
        end

        def draw(key, state)
          _, width, colour, limit = key
          text = Panel.render(state.merge(train_prs: kept_prs), width: width, colour: colour, limit: limit)
          @drawn.delete_if { |_, found| !fresh?(found[:at]) }
          @drawn[key] = { text: text, at: @now.call }
          text
        end

        def kept_prs
          @kept_prs = nil unless @prs_at && fresh?(@prs_at)
          @kept_prs ||= @train_prs.call.tap { @prs_at = @now.call }
        end

        def fresh?(at) = @now.call - at < @seconds
      end
    end
  end
end
