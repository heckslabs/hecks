# frozen_string_literal: true

require_relative "hub"
require_relative "tile_html"
require_relative "plan_html"
require_relative "tiles"
require_relative "../rules"
require_relative "../board_restart"
require_relative "../load_guard"
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

        # The shortest rest, in seconds, between two drawings of the tiles, whatever the setting.
        GAP_FLOOR = 1

        # @return [Hub] what wakes a stream
        attr_reader :hub

        # @param stages [#fill_tile, #train_tile, #integration_tile] answers each tile's reading
        # @param settings [Hash] `tiles:` and `hub:` stand in for the real ones, `tap:` is the
        #   journal's path, `journal:` stands in for the follower's source, `net_seconds:` for
        #   the `safety_net_seconds` setting, `gap:` for the rest between drawings, and
        #   `registry:` is the one whose world sets the loaded period
        def initialize(stages:, settings: {})
          @tiles = settings[:tiles] || tiles_of(stages)
          @hub = settings[:hub] || hub_of(settings)
        end

        # Starts following the journal and draws every tile once, off the request path, so a page
        # asked for soon after the start already carries its tiles.
        def start
          @hub.start
          @first = Thread.new { @tiles.refresh(0) } if @tiles.respond_to?(:refresh)
        end

        # Waits for the first drawing {#start} began, so a caller that must read drawn tiles (a
        # spec) does not race it. Returns at once when no first drawing was started or it was
        # stopped.
        # @return [Pushed] self
        # @raise [StandardError] what the first drawing raised
        def drawn = tap { @first&.join }

        # Stops following the journal.
        def stop
          @first&.kill
          @hub.stop
        end

        # @param html [String] the page, with a `<!--tile:NAME-->` mark where a tile goes
        # @return [String] the page with each tile drawn in
        def page(html) = html.gsub(MARK) { @tiles.html(Regexp.last_match(1)) }

        private

        def tiles_of(stages)
          drawn = { "fill"        => -> { TileHtml.fill(stages.fill_tile) },
                    "plan"        => -> { PlanHtml.draw(stages.plan_tile) },
                    "train"       => -> { TileHtml.stage(stages.train_tile) },
                    "integration" => -> { TileHtml.integration(stages.integration_tile) } }
          Tiles.new(rows: Rules.rows("Tile"), renderers: drawn)
        end

        def hub_of(settings)
          net = settings.fetch(:net_seconds) { Rules.setting("safety_net_seconds") }
          watch = Watch.new(path: settings.fetch(:tap, PipelineJournal::TAP_PATH), source: settings[:journal])
          Hub.new(tiles: @tiles, watch: watch, net_seconds: net, gap: settings.fetch(:gap) { gap_of(settings[:registry]) })
        end

        # The seconds between two drawings of the tiles: the `tile_redraw_seconds` setting, or the
        # `board_restart` line's `loaded_refresh_seconds` while the machine is loaded; never under
        # {GAP_FLOOR}, so a setting of zero still leaves the board a rest between drawings.
        def gap_of(registry)
          loaded = BoardRestart.limits(registry)[:loaded_refresh_seconds]
          -> { [LoadGuard.loaded? ? loaded : Rules.setting("tile_redraw_seconds"), GAP_FLOOR].max }
        end
      end
    end
  end
end
