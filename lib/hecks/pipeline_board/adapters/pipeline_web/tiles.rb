# frozen_string_literal: true

require "digest"
require_relative "tile_html"
require_relative "../deadline"

module Hecks
  module Adapters
    module PipelineBoard
      # The tiles the board pushes as HTML. Each reads aggregates, as the bluebook's `Tile` rows
      # declare, and no event name: any journal line of a read aggregate makes the tile be drawn
      # again. A tile keeps a digest of what it last drew and a fragment is pushed only when the
      # digest moves, so the dependency is broad and the traffic narrow. A drawing that raises, or
      # runs past {DRAW_SECONDS}, gives that tile an `unknown` note and leaves the others as they
      # were. Only the hub's drawer draws; a request reads the last drawing without the lock, so a
      # slow drawing never holds a page.
      class Tiles
        # Seconds one tile's drawing may take.
        DRAW_SECONDS = 10

        # What a tile shows before its first drawing.
        NOT_DRAWN = "<p class=\"unknown-note\">unknown: not drawn yet</p>"

        # What is pushed for one tile.
        Fragment = Struct.new(:id, :seq, :html) do
          def to_h = { id: id, seq: seq, html: html }
        end

        # @param rows [Array<Hash>] the `Tile` rows: `tile` and `reads` (aggregates, comma
        #   separated)
        # @param renderers [Hash{String => #call}] each tile's drawing, answering its HTML
        def initialize(rows:, renderers:)
          @reads = rows.to_h { |row| [row[:tile], row[:reads].split(",").map(&:strip)] }
          @renderers = renderers
          @drawn = {}
          @lock = Mutex.new
        end

        # @param aggregate [String, nil] the aggregate of a journal line
        # @return [Array<String>] the tiles that read it; none for a line with no aggregate
        def reading(aggregate)
          return [] if aggregate.nil?

          @reads.select { |_, aggregates| aggregates.include?(aggregate) }.keys
        end

        # Draws the named tiles again.
        # @return [Array<Fragment>] those whose drawing differs from the last one
        def changed(ids, seq)
          @lock.synchronize { ids.filter_map { |id| fragment(id, seq) } }
        end

        # @return [Array<Fragment>] every tile as it stands: the last drawing, or a note that it is
        #   not drawn yet; never a drawing made now
        def current(seq) = @reads.keys.map { |id| Fragment.new(id, seq, shown(id)) }

        # Draws every tile again, as the safety net does.
        # @return [Array<Fragment>] those whose drawing differs from the last one
        def refresh(seq) = changed(@reads.keys, seq)

        # @return [String] a tile's last drawing, for the page's first paint
        def html(id) = shown(id)

        private

        def shown(id) = @drawn[id]&.last || NOT_DRAWN

        def fragment(id, seq)
          before = @drawn[id]&.first
          digest, html = draw(id)
          Fragment.new(id, seq, html) unless digest == before
        end

        def draw(id)
          html = Deadline.run(DRAW_SECONDS, "drawing #{id}") { @renderers.fetch(id).call }
          @drawn[id] = [Digest::SHA1.hexdigest(html), html]
        rescue StandardError => e
          note = TileHtml.unknown(unknown: "#{e.class}: #{e.message.to_s.slice(0, 100)}")
          @drawn[id] = [Digest::SHA1.hexdigest(note), note]
        end
      end
    end
  end
end
