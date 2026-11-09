# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    class BootBudget
      # The recent lines of the launcher's usage record, read from the end of the file. The record
      # grows by a line for every launcher run, so a reader that parses all of it on every read pays
      # for the whole history; this one stops at the first line older than the window it was asked
      # for, and never reads more than its byte limit.
      #
      # The record is shared by every checkout, and one that runs older launcher code appends lines
      # with no time, so a line without a time is skipped, not taken for the end of the window.
      module UsageTail
        # Bytes read from the file at a time.
        CHUNK = 65_536

        # The most bytes read from the end of the record.
        LIMIT = 8 * 1024 * 1024

        # A `YYYY-MM-DD` date, which compares as text.
        DATE = /\A\d{4}-\d{2}-\d{2}\z/

        # The entries of a window, newest first, and whether the byte limit cut the window short.
        class Window < Array
          # @return [Boolean] true when the limit ended the read before the window's start
          attr_accessor :capped
        end

        module_function

        # @param cutoff [Time] the start of the window
        # @param path [String, nil] the usage record; the launcher's own when nil
        # @param limit [Integer] the most bytes read from the end of the record
        # @return [Window] the entries of the window, newest first; empty with no record
        def since(cutoff, path: nil, limit: LIMIT)
          rows = Window.new
          floor = scan(path || Driving::UsageLog.path, cutoff, limit) { |row| rows << row }
          rows.capped = floor.to_i.positive?
          rows
        rescue SystemCallError, IOError
          rows
        end

        # Whether an entry falls in the window. A run carries the time it began (`at`); one recorded
        # before that field existed counts only when it carries a boot time and its day is the
        # window's first or later (the day is all it says, so it is approximate). An entry with
        # neither is too old to price.
        #
        # @param row [Hash] one usage entry
        # @param cutoff [Time] the start of the window
        # @return [Boolean]
        def recent?(row, cutoff)
          began = stamp(row)
          return began >= cutoff if began

          row["boot_ms"].is_a?(Numeric) && on_or_after_day?(row, cutoff)
        end

        # @param row [Hash] one usage entry
        # @return [Boolean] whether the entry carries no start time, so its place in the window
        #   is judged by its day alone
        def approximate?(row) = stamp(row).nil?

        # @param row [Hash] one usage entry
        # @return [Time, nil] when the run began, nil when the entry says none
        def stamp(row)
          Time.parse(row["at"].to_s) if row["at"]
        rescue ArgumentError
          nil
        end

        # Hands each entry of the window to the block, newest first, and answers the byte offset
        # the limit stopped the read at (positive when the window's start was left unreached), or
        # nil when an entry before the window ended the read.
        def scan(path, cutoff, limit, &)
          each_line_backwards(path, limit) do |line|
            row = parse(line)
            next unless row
            break if before_window?(row, cutoff)

            yield row
          end
        end

        # Whether the entry proves the read has passed the window's start: a stamped one older than
        # the cutoff, or an unstamped one whose day is. A line with neither is skipped.
        def before_window?(row, cutoff)
          began = stamp(row)
          return began < cutoff if began

          day_before?(row, cutoff)
        end

        def day_before?(row, cutoff)
          day = row["date"].to_s
          day.match?(DATE) && day < cutoff.utc.strftime("%Y-%m-%d")
        end

        # A run's day is the window's first day or later; an entry with no day is neither.
        def on_or_after_day?(row, cutoff)
          day = row["date"].to_s
          day.match?(DATE) && day >= cutoff.utc.strftime("%Y-%m-%d")
        end

        def parse(line)
          row = JSON.parse(line.force_encoding(Encoding::UTF_8))
          row if row.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        def each_line_backwards(path, limit, &)
          File.open(path, "rb") { |file| read_backwards(file, limit, &) }
        end

        # Reads chunks from the end. Answers the offset the limit stopped it at: positive when the
        # file's start was left unread, zero when the whole file was read.
        def read_backwards(file, limit, &)
          position = file.size
          floor = [position - limit, 0].max
          carry = +""
          while position > floor
            step = [CHUNK, position - floor].min
            position -= step
            carry = take(file, position, step, carry, &)
          end
          yield carry if position.zero? && !carry.empty?
          floor
        end

        # The complete lines of one chunk, last first; the partial one at its start is carried to
        # the chunk before it. A file that shrank since its size was read gives a short or empty
        # chunk, which reads as no lines.
        def take(file, position, step, carry, &)
          file.seek(position)
          lines = ((file.read(step) || "") + carry).split("\n", -1)
          rest = lines.shift.to_s
          lines.reverse_each(&)
          rest
        end
      end
    end
  end
end
