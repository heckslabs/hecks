# frozen_string_literal: true

require_relative "bad_day/rows"

module Hecks
  module Adapters
    module PipelineBoard
      # One staged bad day for the board: main is red and an episode is being reverted, the load is
      # short so admission is closed, three entries wait on a person and two stand too long. It is
      # the state `/api/state` would hold, written down, so every picture of a bad day shows the
      # same day. It reads nothing from the machine.
      class BadDay
        # The moment the day is staged at; fixed, so two drawings of it are the same picture.
        AT = "2026-11-20T15:10:00Z"

        # @return [Hash] the state of the staged day, in the shape of {PipelineStages#state}
        def state
          board = BadDayRows.board(AT)
          BadDayRows.sections(AT).merge(board: board, stages: BadDayRows.strip, waiting_on_you: waiting)
        end

        # @return [Hash] the tile the page draws for a section this day does not stage
        def unstaged = { unknown: "the staged bad day does not stage this" }

        alias fill_tile unstaged
        alias plan_tile unstaged
        alias project_plan_tile unstaged

        # @return [Hash] the Train row of the strip
        def train_tile = BadDayRows.strip.find { |row| row[:name] == "Train" }

        # @return [Hash] the Integration row of the strip
        def integration_tile = BadDayRows.strip.find { |row| row[:name] == "Integration" }

        # @param _lines [Integer] how many events the page asks for
        # @return [Array<Hash>] the staged events, newest first
        def journal_feed(_lines = nil) = BadDayRows.events(AT)

        # @return [Array<Hash>] the open train pull requests
        def train_prs = BadDayRows.board(AT)[:train]

        # @return [nil] a staged day has no run to open
        def run_detail(_key) = nil

        # @return [nil] a staged day has no boarding to open
        def train_detail(_key) = nil

        private

        def waiting
          ids = BadDayRows.waiting.map { |row| row[:id] }
          { count: ids.size, ids: ids, help: [], help_unknown: "staged: no help is wanted" }
        end
      end
    end
  end
end
