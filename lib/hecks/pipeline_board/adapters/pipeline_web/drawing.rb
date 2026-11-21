# frozen_string_literal: true

require "tmpdir"
require_relative "pictures"
require_relative "bad_day"

module Hecks
  module Adapters
    module PipelineBoard
      # What the `Web` port's `DrawPages` asks of {PipelineWeb}: every page of the board drawn to an
      # image, from the live state or from the staged bad day ({BadDay}).
      module Drawing
        # What the board holds from outside its own readers: the registry, the browser pictures are
        # drawn with, and the watch from outside the process.
        def outside(registry, settings)
          { registry: registry, browser: settings[:browser], sentinel: settings.fetch(:sentinel) { PipelineBoard::Sentinel.method(:stand) } }
        end

        # @param held [Hash] `state:` `live` or `bad_day`, `into:` the directory for the images
        # @return [Hash{Symbol => Hash}] `last:` what was drawn
        # @raise [PipelineBoard::Unavailable] for a state the board does not draw, or no browser
        def draw_pages(**held)
          state, into = %i[state into].map { |key| held[key].is_a?(Hash) ? held[key][:value] : held[key] }
          pictures = Pictures.new(app: picture_board(state), browser: @outside[:browser])
          { last: { value: "drew #{pictures.draw(state: state, into: into).size} pages into #{into}" } }
        end

        # The board a picture of this state is drawn from: this one, or the staged bad day served
        # through the same pages.
        def picture_board(state)
          return self if state == "live"
          raise Unavailable, "no such state to draw: #{state}" unless state == "bad_day"

          self.class.new(settings: staged_settings, root: @root)
        end

        # The settings of the staged board: its own stages, a journal tap in a directory of its own,
        # and a launcher that refuses, so drawing it reads and writes nothing of the owner's.
        def staged_settings
          tap = File.join(Dir.mktmpdir("board-bad-day"), "events.jsonl")
          { stages: BadDay.new, background: false, tap: tap, load_guard: false, sentinel: nil,
            launcher: ->(*) { raise Unavailable, "the staged bad day takes no steps" } }
        end
      end
    end
  end
end
