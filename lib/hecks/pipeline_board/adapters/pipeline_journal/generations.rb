# frozen_string_literal: true

require "hecks/runtime/event_tap"
require_relative "tail"

module Hecks
  module Adapters
    module PipelineBoard
      # The lines of the whole event log (the rotated generations the runtime's tap keeps, then
      # the live file) that name one of a set of event names. Each file is followed by a {Tail}
      # and known by its inode, which a rotation keeps, so a rotated generation is read once and
      # the live file only where it grew. One pass over a file keeps the lines of every indexed
      # name; what is held of a generation goes when the tap drops that file. Callers take turns
      # (see {Tap}).
      class Generations
        # What is held of one file: its follower and the lines that name an indexed event.
        Held = Struct.new(:tail, :lines) do
          # @return [Integer] the bytes read of the file
          def bytes_read = tail.bytes_read

          # @return [Tail::Read] what the file gained, read from where it is now
          def advance(file) = tail.advance(file)
        end

        # @return [Integer] moves whenever the held lines change
        attr_reader :version

        # @param path [String] the live log's path
        # @param names [#call] answers the bare event names indexed from the first read on
        def initialize(path, names)
          @path = path
          @declared = names
          @held = {}
          @version = 0
          @dropped_bytes = 0
        end

        # Reads what the log gained. A name outside the index widens it, and every file is then
        # read again once.
        #
        # @param names [Array<String>] bare event names about to be asked for
        # @return [Integer] the version of the held lines
        def refresh(names)
          widen(names)
          found = files
          drop(@held.keys - found.keys)
          found.each { |identity, file| take(identity, file) }
          @version
        end

        # @param names [Array<String>] bare event names
        # @return [Array<String>] the held lines naming one of them, oldest first
        def lines(names)
          @held.values.flat_map(&:lines).select { |line| names?(line, names) }
        end

        # @return [Integer] the bytes read so far, over every file followed
        def bytes_read = @dropped_bytes + @held.values.sum(&:bytes_read)

        private

        def widen(names)
          @indexed ||= @declared.call.uniq
          return if (names - @indexed).empty?

          @indexed |= names
          drop(@held.keys)
        end

        # Forgets the files the log dropped, keeping the count of what was read of them.
        def drop(gone)
          return if gone.empty?

          gone.each { |identity| @dropped_bytes += @held.delete(identity).bytes_read }
          @version += 1
        end

        # Each file of the log by its identity, oldest first.
        def files
          rotated = (1..Hecks::Runtime::EventTap::KEPT).map { |n| "#{@path}.#{n}" }
          (rotated.reverse + [@path]).filter_map { |file| identified(file) }.to_h
        end

        def identified(file)
          stat = File.stat(file)
          [[stat.dev, stat.ino], file] if stat.file?
        rescue SystemCallError
          nil
        end

        def take(identity, file)
          held = @held[identity] ||= Held.new(Tail.new, [])
          read = held.advance(file)
          fresh = read.lines.select { |line| names?(line, @indexed) }
          return if fresh.empty? && !read.anew

          keep(held, fresh, read.anew)
        end

        def keep(held, fresh, anew)
          held.lines.clear if anew
          held.lines.concat(fresh)
          @version += 1
        end

        def names?(line, names) = names.any? { |name| line.include?("\"#{name}\"") }
      end
    end
  end
end
