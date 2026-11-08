# frozen_string_literal: true

require_relative "panel/kit"
require_relative "panel/overview"
require_relative "panel/work"

module Hecks
  module Adapters
    module PipelineBoard
      # The pipeline board's state drawn as a fixed-width text panel: plain ASCII boxes, no colour
      # unless asked, nothing read and nothing written. It draws the hash `/api/state` serves
      # (plus `train_prs`, the open train pull requests) and decides nothing about what is shown.
      module Panel
        WIDTHS = (60..200)
        DEFAULT_WIDTH = 80
        DEFAULT_LIMIT = 5

        module_function

        # @param state [Hash] the board's state; each section is an answer or `{unknown: reason}`
        # @param width [Integer, nil] the panel's columns, held to 60..200 (80 when nil)
        # @param colour [Boolean] whether rows are coloured by their state
        # @param limit [Integer, nil] how many planned Work items and finished sessions to list (5)
        # @return [String] the panel, one line per row, ending in a newline
        def render(state, width: nil, colour: false, limit: nil)
          columns = (width || DEFAULT_WIDTH).to_i.clamp(WIDTHS.min, WIDTHS.max)
          overview = Overview.new(state, columns - 4)
          work = Work.new(state, (limit || DEFAULT_LIMIT).to_i.clamp(1, 50), columns - 4)
          boxes = boxes(state, overview, work)
          "#{boxes.flat_map { |title, rows| Kit.box(title, rows, columns, colour) }.join("\n")}\n"
        end

        # @return [Array<Array(String, Array)>] each box's title and rows, top to bottom
        def boxes(state, overview, work)
          [["Pipeline board #{state[:generated_at]}", overview.counts], ["Stages", overview.stages],
           ["Metrics", overview.tiles], ["Main CI", overview.runs], ["Sessions", work.sessions],
           ["Open train PRs", work.pulls], ["Planned work", work.planned], ["Agents", work.agents]]
        end
      end
    end
  end
end
