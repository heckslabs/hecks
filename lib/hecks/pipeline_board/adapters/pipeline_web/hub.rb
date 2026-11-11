# frozen_string_literal: true

require_relative "tiles"
require_relative "../pipeline_journal/watch"

module Hecks
  module Adapters
    module PipelineBoard
      # Turns the journal's growth into pushes. One watch reads the journal; each line wakes every
      # open reader and carries the fragments of the tiles that line changed. The one timer is the
      # safety net: every `net_seconds` it draws every tile again and wakes the readers, so a line
      # the file watch missed is still caught and a dead connection shows when its write raises.
      class Hub
        # What a reader is woken with: the journal's `seq`, the fragments to push and whether the
        # safety net, not a journal line, woke it.
        Wake = Struct.new(:seq, :fragments, :net)

        # @param tiles [Tiles] the tiles pushed
        # @param watch [Watch] the journal follower
        # @param net_seconds [Numeric] the safety net's period (the `safety_net_seconds` setting)
        def initialize(tiles:, watch:, net_seconds:)
          @tiles = tiles
          @watch = watch
          @net_seconds = net_seconds
          @readers = []
          @seq = 0
          @lock = Mutex.new
        end

        # Starts following the journal and the safety net.
        # @return [Hub] self
        def start
          @watch.start { |row| line(row) }
          @net = Thread.new { loop { net } }
          self
        end

        # Stops the watch and the safety net.
        def stop
          @watch.stop
          @net&.kill
        end

        # @return [Queue] wakes for one reader; give it back with {#leave}
        def join
          Queue.new.tap { |queue| @lock.synchronize { @readers << queue } }
        end

        # @param queue [Queue] a reader's wakes
        def leave(queue) = @lock.synchronize { @readers.delete(queue) }

        # @return [Array<Tiles::Fragment>] every tile as it stands, for a reader just joined
        def current = @tiles.current(@seq)

        private

        def line(row)
          @seq = row[:seq] || (@seq + 1)
          wake(Wake.new(@seq, @tiles.changed(@tiles.reading(row[:aggregate]), @seq), false))
        end

        def net
          sleep @net_seconds
          wake(Wake.new(@seq, @tiles.refresh(@seq), true))
        end

        def wake(message) = @lock.synchronize { @readers.each { |queue| queue << message } }
      end
    end
  end
end
