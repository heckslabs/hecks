# frozen_string_literal: true

require "fileutils"
require "time"
require "zlib"
require_relative "../event"
require_relative "folding"

module Hecks
  module Runtime
    class EventTap
      # The compressed generations a tap keeps once they leave the numbered files beside the log:
      # one gzip file each under `<path>.archive`, named for the time of its newest line and the
      # sequence number of its first. A file is kept until its newest line is older than
      # `keep_hours`; past `max_bytes` in total the oldest go first, so a flood cannot fill the
      # disk. The newest file is never removed for size.
      class Archive
        # The suffix of an archived generation.
        SUFFIX = ".jsonl.gz"

        # @param path [String] the live log's path
        # @param keep_hours [Numeric] hours an archived generation is kept
        # @param max_bytes [Integer] the most bytes the archive holds
        def initialize(path, keep_hours:, max_bytes:)
          @dir = "#{File.expand_path(path.to_s)}.archive"
          @keep_seconds = keep_hours.to_f * 3600
          @max_bytes = max_bytes.to_i
        end

        # Moves a generation into the archive, its repeats folded, then prunes the archive. The
        # generation is removed only once its archive file is in place.
        #
        # @param file [String] the generation leaving the numbered files
        # @return [String] the archive file written
        def store(file)
          FileUtils.mkdir_p(@dir)
          written = File.mtime(file)
          lines = Folding.new.fold(File.foreach(file, chomp: true))
          target = File.join(@dir, "#{written.utc.strftime("%Y%m%dT%H%M%SZ")}-#{first_seq(lines)}#{SUFFIX}")
          write(target, lines, written)
          File.delete(file)
          prune
          target
        end

        # @return [Array<String>] the archive's files, oldest first
        def files = Dir.glob(File.join(@dir, "*#{SUFFIX}"))

        # @return [Array<String>] every archived line, oldest first
        def lines
          files.flat_map { |file| Zlib::GzipReader.open(file) { |gzip| gzip.each_line.map(&:chomp) } }
        end

        # Removes the files older than the hours kept, then the oldest past the byte limit.
        #
        # @param at [String] the ISO 8601 time the ages are counted from
        # @return [void]
        def prune(at: Event.stamp)
          now = Time.iso8601(at)
          files.each { |file| File.delete(file) if now - File.mtime(file) > @keep_seconds }
          kept = files
          File.delete(kept.shift) while kept.size > 1 && kept.sum { |file| File.size(file) } > @max_bytes
        end

        private

        def first_seq(lines)
          JSON.parse(lines.first.to_s).fetch("seq", 0)
        rescue JSON::ParserError, NoMethodError
          0
        end

        # Writes under a temporary name and renames, so a reader never sees a part-written file.
        def write(target, lines, written)
          part = "#{target}.part"
          Zlib::GzipWriter.open(part) { |gzip| lines.each { |line| gzip.puts(line) } }
          File.utime(written, written, part)
          File.rename(part, target)
        end
      end
    end
  end
end
