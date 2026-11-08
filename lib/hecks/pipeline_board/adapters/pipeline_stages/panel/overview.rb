# frozen_string_literal: true

require_relative "kit"
require_relative "../../../../check_conclusion"

module Hecks
  module Adapters
    module PipelineBoard
      module Panel
        # The panel's top: the stage counts, the stage details, the metric tiles and recent main CI.
        # Each method answers the rows of one box, `[text, tone]` each. A section that could not be
        # read (`{unknown: reason}`) is one row saying so.
        class Overview
          # The arrow of a rise (true) and of a fall (false).
          ARROWS = { true => "^", false => "v" }.freeze

          # @param state [Hash] the board's state, as `/api/state` serves it
          # @param size [Integer] the characters a row may hold
          def initialize(state, size)
            @state = state
            @size = size
          end

          # @return [Array<Array(String, String)>] the stage counts, wrapped into rows
          def counts
            stages = list(:stages)
            return stages unless stages.first.is_a?(Hash)

            items = stages.map { |stage| ["#{Kit.mark(stage[:state])} #{label(stage)} #{stage[:count]}", stage[:state]] }
            Kit.wrap(items, @size, " | ")
          end

          # @return [Array<Array(String, String)>] one row per stage with its state and detail
          def stages
            list(:stages).map { |stage| stage.is_a?(Hash) ? stage_row(stage) : stage }
          end

          # @return [Array<Array(String, String)>] one row per metric tile: value, trend and detail
          def tiles
            list(:metrics).map { |tile| tile.is_a?(Hash) ? tile_row(tile) : tile }
          end

          # @return [Array<Array(String, String)>] the last CI runs on main, oldest first, as marks
          def runs
            ran = list(:ci_runs)
            return ran unless ran.first.is_a?(Hash)

            items = ran.map { |run| ["[#{outcome(run)}] #{run[:sha]}", tone(run)] }
            [*Kit.wrap(items, @size), ["[+] passed  [x] failed  [~] running  [-] other; oldest first", "unknown"]]
          end

          private

          def label(stage) = stage[:name] == "Local main" ? "Local main ahead" : stage[:name]

          def list(key)
            found = @state[key]
            return [["unknown: #{found[:unknown]}", "unknown"]] if found.is_a?(Hash) && found.key?(:unknown)
            return [["unknown: no data", "unknown"]] unless found.is_a?(Array)

            found.empty? ? [["nothing to show", "unknown"]] : found
          end

          def stage_row(stage)
            cells = [Kit.mark(stage[:state]), stage[:name].to_s.ljust(11), stage[:count].to_s.ljust(9), stage[:detail]]
            [cells.join(" "), stage[:state]]
          end

          def tile_row(tile)
            value = tile[:value].nil? ? "-" : "#{tile[:value]} #{tile[:unit]}".strip
            cells = [tile[:label].to_s.ljust(24), value.ljust(10), trend(tile[:trend]).ljust(16), tile[:detail]]
            [cells.join(" ").rstrip, tile[:state]]
          end

          # @return [String] an arrow and the change, then whether it is better or worse
          def trend(change)
            return "" unless change.is_a?(Hash)

            delta = change[:delta].to_f
            arrow = delta.zero? ? "=" : ARROWS.fetch(delta.positive?)
            verdict = { true => " better", false => " worse" }.fetch(change[:better], "")
            "#{arrow} #{"+" if delta.positive?}#{change[:delta]} #{change[:unit]}#{verdict}"
          end

          def outcome(run)
            return "~" unless run[:status] == "completed"
            return "+" if run[:conclusion] == "success"

            Hecks::CheckConclusion.clean?(run[:conclusion]) ? "-" : "x"
          end

          def tone(run) = { "+" => "ok", "x" => "failed", "~" => "working" }.fetch(outcome(run), "unknown")
        end
      end
    end
  end
end
