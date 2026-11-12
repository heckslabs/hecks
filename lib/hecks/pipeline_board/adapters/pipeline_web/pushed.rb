# frozen_string_literal: true

require_relative "hub"
require_relative "tile_html"
require_relative "plan_html"
require_relative "tiles"
require_relative "../rules"
require_relative "../pipeline_journal"

module Hecks
  module Adapters
    module PipelineBoard
      # Everything the board pushes instead of being asked: the tiles it draws as HTML, from the
      # same readings that hold their data and the aggregates the bluebook's `Tile` rows say they
      # read, and the hub that follows the journal and wakes the open streams. The board's page
      # carries each tile already drawn, so it reads whole with the stream off.
      class Pushed
        # A tile's place on the page: `<!--tile:NAME-->`.
        MARK = /<!--tile:(\w+)-->/

        # @return [Hub] what wakes a stream
        attr_reader :hub

        # @param stages [#fill_tile, #train_tile] answers each tile's reading
        # @param settings [Hash] `tiles:` and `hub:` stand in for the real ones, `tap:` is the
        #   journal's path, `journal:` stands in for the follower's source and `net_seconds:` for
        #   the `safety_net_seconds` setting
        def initialize(stages:, settings: {})
          @tiles = settings[:tiles] || tiles_of(stages)
          @hub = settings[:hub] || hub_of(settings)
        end

        # Starts following the journal.
        def start = @hub.start

        # Stops following the journal.
        def stop = @hub.stop

        # @param html [String] the page, with a `<!--tile:NAME-->` mark where a tile goes
        # @return [String] the page with each tile drawn in
        def page(html) = html.gsub(MARK) { @tiles.html(Regexp.last_match(1)) }

        private

        def tiles_of(stages)
          drawn = { "fill"  => -> { TileHtml.fill(stages.fill_tile) },
                    "plan"  => -> { PlanHtml.draw(stages.plan_tile) },
                    "train" => -> { TileHtml.stage(stages.train_tile) } }
          Tiles.new(rows: Rules.rows("Tile"), renderers: drawn)
        end

        def hub_of(settings)
          net = settings.fetch(:net_seconds) { Rules.setting("safety_net_seconds") }
          watch = Watch.new(path: settings.fetch(:tap, PipelineJournal::TAP_PATH), source: settings[:journal])
          Hub.new(tiles: @tiles, watch: watch, net_seconds: net)
        end
      end
    end
  end
end
