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
      # raises. The rest starts when a drawing ends and lasts the gap or as long as the drawing
      # took, whichever is longer; one pen is held while drawing, so a drawing slower than the gap
      # is never followed at once by another, nor run beside one.
      class Hub
        # The hub's time: `now` answers monotonic seconds and `rest` waits; a spec's stands in.
        module Clock
          def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          def self.rest(seconds) = sleep(seconds)
        end

        # What a reader is woken with: the journal's `seq`, the fragments to push and whether the
        # safety net, not a journal line, woke it.
        Wake = Struct.new(:seq, :fragments, :net)

        # @param tiles [Tiles] the tiles pushed
        # @param watch [Watch] the journal follower
        # @param net_seconds [Numeric] the safety net's period (the `safety_net_seconds` setting)
        # @param gap [#call] answers the seconds the drawer rests after a drawing (the
        #   `tile_redraw_seconds` setting, or the loaded period while the machine is loaded)
        # @param clock [#now, #rest] the hub's time ({Clock}, or a spec's)
        def initialize(tiles:, watch:, net_seconds:, gap: -> { 0 }, clock: Clock)
          @tiles = tiles
          @watch = watch
          @net_seconds = net_seconds
          @gap = gap
          @readers = []
          @marked = []
          @due = Queue.new
          @seq = 0
          @lock, @pen = Array.new(2) { Mutex.new }
          @clock = clock
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
        # after a drawing or the drawer holds the pen; the tiles then stay marked and the drawer
        # draws them when the rest ends.
        def line(row)
          @seq = row[:seq] || (@seq + 1)
          @lock.synchronize { @marked |= @tiles.reading(row[:aggregate]) }
          wake(Wake.new(@seq, drawn_with_the_line || left_for_the_drawer, false))
        end

        # The marked tiles drawn on the watch's thread, or nil while resting or the pen is held.
        def drawn_with_the_line
          return unless @pen.try_lock

          begin
            drawing unless resting?
          ensure
            @pen.unlock
          end
        end

        def left_for_the_drawer = [].tap { @due << :marked }

        # The rest is over when no drawing has set one (`nil.to_f` is 0).
        def resting? = @clock.now < rest_until

        def rest_until = @rest_until.to_f

        # The marked tiles, drawn once; the rest starts when the drawing ends. Called with the pen.
        def drawing
          ids = @lock.synchronize { @marked.tap { @marked = [] } }
          return [] if ids.empty?

          started = @clock.now
          begin
            @tiles.changed(ids, @seq)
          ensure
            ended = @clock.now
            @rest_until = ended + [@gap.call.to_f, ended - started].max
          end
        end

        # Waits out the rest, then draws what the lines of the rest marked and wakes the readers
        # when a drawing changed. The pen is held throughout, so a line draws nothing meanwhile.
        def draw
          @due.pop
          @due.clear
          fragments = @pen.synchronize do
            left = rest_until - @clock.now
            @clock.rest(left) if left.positive?
            drawing
          end
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
