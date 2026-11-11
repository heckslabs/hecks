# frozen_string_literal: true

require "digest"
require_relative "tile_html"

module Hecks
  module Adapters
    module PipelineBoard
      # The tiles the board pushes as HTML. Each reads aggregates, as the bluebook's `Tile` rows
      # declare, and no event name: any journal line of a read aggregate makes the tile be drawn
      # again. A tile keeps a digest of what it last drew and a fragment is pushed only when the
      # digest moves, so the dependency is broad and the traffic narrow. A drawing that raises
      # gives that tile an `unknown` note and leaves the others as they were.
      class Tiles
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

        # @return [Array<Fragment>] every tile as it stands: the last drawing, or one made now
        def current(seq)
          @lock.synchronize { @reads.keys.map { |id| Fragment.new(id, seq, @drawn[id]&.last || draw(id).last) } }
        end

        # Draws every tile again, as the safety net does.
        # @return [Array<Fragment>] those whose drawing differs from the last one
        def refresh(seq) = changed(@reads.keys, seq)

        # @return [String] a tile's HTML now, for the page's first paint
        def html(id) = @lock.synchronize { draw(id).last }

        private

        def fragment(id, seq)
          before = @drawn[id]&.first
          digest, html = draw(id)
          Fragment.new(id, seq, html) unless digest == before
        end

        def draw(id)
          html = @renderers.fetch(id).call
          @drawn[id] = [Digest::SHA1.hexdigest(html), html]
        rescue StandardError => e
          note = TileHtml.unknown(unknown: "#{e.class}: #{e.message.to_s.slice(0, 100)}")
          @drawn[id] = [Digest::SHA1.hexdigest(note), note]
        end
      end
    end
  end
end
