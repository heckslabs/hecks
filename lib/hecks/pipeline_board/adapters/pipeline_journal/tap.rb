# frozen_string_literal: true

require_relative "tail"
require_relative "generations"
require_relative "linking"

module Hecks
  module Adapters
    module PipelineBoard
      # Reads the runtime's opt-in event log (`Hecks::Runtime::EventTap`): one JSON line per event
      # and one per policy delivery, which this reader attaches to the event it answered. It reads
      # the log by byte offset, so a call costs what was written since the last one and not the
      # size of the log, and it keeps an answer while the log stands as it was read. It opens the
      # files for reading only; a missing file holds no events.
      class Tap
        include Linking

        TAIL_LINES = 600

        # @param path [String] the log's path
        # @param names [#call] answers the bare event names {#named} is asked for, so one pass over
        #   a rotated file serves them all
        def initialize(path, names: -> { [] })
          @path = path
          @tail = Tail.new(last: TAIL_LINES)
          @window = []
          @generations = Generations.new(path, names)
          @named = {}
          @lock = Mutex.new
        end

        # @return [Array<Hash>] the newest events of the live log as board rows, oldest first, each
        #   with the reactions the log holds for it
        def rows
          @lock.synchronize do
            read = @tail.advance(@path)
            @recent = nil if read.anew || read.lines.any?
            @window = read.anew ? read.lines : (@window + read.lines).last(TAIL_LINES)
            @recent ||= link(parse(@window))
          end
        end

        # Every logged event of the given names, read from the whole log rather than its tail, so
        # an event that is rarely raised is not pushed out by the traffic after it.
        #
        # @param names [Array<String>] bare event names
        # @return [Array<Hash>] the matching events as board rows, oldest first
        def named(names)
          @lock.synchronize do
            version = @generations.refresh(names)
            kept = @named[names]
            next kept.last if kept && kept.first == version

            (@named[names] = [version, linked(names)]).last
          end
        end

        # @return [Integer] the bytes of the log read so far, across the tail and every generation
        def bytes_read = @lock.synchronize { @tail.bytes_read + @generations.bytes_read }

        private

        def linked(names)
          link(parse(@generations.lines(names))).select { |row| names.include?(bare(row[:name])) }
        end
      end
    end
  end
end
