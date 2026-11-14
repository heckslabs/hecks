# frozen_string_literal: true

require_relative "tiles"
require_relative "../pipeline_journal/watch"

module Hecks
  module Adapters
    module PipelineBoard
      # Turns the journal's growth into pushes. One watch reads the journal; each line wakes every
      # open reader at once, so the event feed moves with the journal, and marks the tiles that
      # line changed. The marked tiles are drawn with the line, and the hub then rests for the
      # `gap`: lines that arrive in the rest only mark, and one drawer draws what they marked when
      # the rest ends. A run of journal lines so costs one drawing of a tile per gap, not one per
      # line, and the cost of a busy pipeline does not grow with how busy it is. The one timer is
      # the safety net: every `net_seconds` it draws every tile again and wakes the readers, so a
      # line the file watch missed is still caught and a dead connection shows when its write
      # raises.
      class Hub
        # What a reader is woken with: the journal's `seq`, the fragments to push and whether the
        # safety net, not a journal line, woke it.
        Wake = Struct.new(:seq, :fragments, :net)

        # @param tiles [Tiles] the tiles pushed
        # @param watch [Watch] the journal follower
        # @param net_seconds [Numeric] the safety net's period (the `safety_net_seconds` setting)
        # @param gap [#call] answers the seconds the drawer rests after a drawing (the
        #   `tile_redraw_seconds` setting, or the loaded period while the machine is loaded)
        def initialize(tiles:, watch:, net_seconds:, gap: -> { 0 })
          @tiles = tiles
          @watch = watch
          @net_seconds = net_seconds
          @gap = gap
          @readers = []
          @marked = []
          @due = Queue.new
          @rest_until = 0.0
          @seq = 0
          @lock = Mutex.new
        end

        # Starts following the journal, the drawer and the safety net.
        # @return [Hub] self
        def start
          @watch.start { |row| line(row) }
          @drawer = Thread.new { loop { draw } }
          @net = Thread.new { loop { net } }
          self
        end

        # Stops the watch, the drawer and the safety net.
        def stop
          @watch.stop
          [@drawer, @net].each { |thread| thread&.kill }
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

        # One wake per line. It carries the drawing of the marked tiles unless the hub is resting
        # after a drawing; the tiles then stay marked and the drawer draws them when the rest ends.
        def line(row)
          @seq = row[:seq] || (@seq + 1)
          @lock.synchronize { @marked |= @tiles.reading(row[:aggregate]) }
          wake(Wake.new(@seq, resting? ? left_for_the_drawer : drawing, false))
        end

        def left_for_the_drawer = [].tap { @due << :marked }

        def resting? = monotonic < @rest_until

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # The marked tiles, drawn once; the rest starts with a drawing.
        def drawing
          ids = @lock.synchronize { @marked.tap { @marked = [] } }
          return [] if ids.empty?

          @rest_until = monotonic + @gap.call.to_f
          @tiles.changed(ids, @seq)
        end

        # Waits out the rest, then draws what the lines of the rest marked and wakes the readers
        # when a drawing changed.
        def draw
          @due.pop
          @due.clear
          left = @rest_until - monotonic
          sleep(left) if left.positive?
          fragments = drawing
          wake(Wake.new(@seq, fragments, false)) unless fragments.empty?
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
