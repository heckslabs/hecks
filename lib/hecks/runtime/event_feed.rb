# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../naming"
require_relative "event_tap"

module Hecks
  module Runtime
    # Reads the event tap (`Runtime::EventTap`) past a sequence number, filtered by aggregate and
    # by event name. It opens the log files and no domain, so reading boots nothing and reacts to
    # nothing. It reads every rotated generation oldest first, so a cursor carries across rotation.
    #
    # It takes the tap's lock shared while it reads, so a line the tap is still writing is never
    # half read. A line that does not parse is skipped.
    class EventFeed
      # @param path [String] the live log; its rotated generations sit beside it as `<path>.N`
      def initialize(path:)
        @path = File.expand_path(path.to_s)
      end

      # @param since [Integer] answer only lines whose sequence number is larger
      # @param aggregates [Array<String>] keep lines of these aggregates; empty keeps all
      # @param names [Array<String>] keep lines whose event (or the event a reaction answered)
      #   is one of these; empty keeps every name
      # @param limit [Integer] the most lines scanned in one read
      # @return [Hash{Symbol => Object}] `events:` the kept lines, `cursor:` the last sequence
      #   number scanned, to pass as the next `since`
      def read(since: 0, aggregates: [], names: [], limit: 100)
        scanned = with_lock { lines_after(since).first(limit) }
        kept = scanned.select { |line| keep?(line, aggregates, names) }
        { events: kept, cursor: scanned.last&.fetch("seq") || since }
      end

      private

      def lines_after(since)
        generations.flat_map { |file| parse(file) }
                   .select { |line| line["seq"].to_i > since }
                   .sort_by { |line| line["seq"].to_i }
      end

      def generations
        rotated = (1..Hecks::Runtime::EventTap::KEPT).map { |n| "#{@path}.#{n}" }.select { |file| File.file?(file) }
        rotated.reverse + [@path].select { |file| File.file?(file) }
      end

      def parse(file)
        File.readlines(file, chomp: true).filter_map do |text|
          JSON.parse(text)
        rescue JSON::ParserError
          nil
        end
      end

      def keep?(line, aggregates, names)
        aggregate_kept?(line["aggregate"], aggregates) && (names.empty? || names.include?(line["event"]))
      end

      def aggregate_kept?(aggregate, wanted)
        wanted.empty? || wanted.any? { |name| matches?(aggregate.to_s, name.to_s) }
      end

      def matches?(aggregate, name)
        aggregate == name || Naming.demodulise(aggregate).casecmp?(name)
      end

      def with_lock
        FileUtils.mkdir_p(File.dirname(@path))
        File.open("#{@path}.lock", File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_SH)
          yield
        end
      end
    end
  end
end
