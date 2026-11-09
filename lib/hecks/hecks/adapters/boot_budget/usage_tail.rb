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
      module UsageTail
        # Bytes read from the file at a time.
        CHUNK = 65_536

        # The most bytes read from the end of the record.
        LIMIT = 8 * 1024 * 1024

        module_function

        # @param cutoff [Time] the start of the window
        # @param path [String, nil] the usage record; the launcher's own when nil
        # @return [Array<Hash>] the entries of the window, newest first; empty with no record
        def since(cutoff, path: nil)
          rows = []
          each_line_backwards(path || Driving::UsageLog.path) do |line|
            row = parse(line)
            next unless row
            break unless recent?(row, cutoff)

            rows << row
          end
          rows
        rescue SystemCallError
          []
        end

        # Whether an entry falls in the window. A run carries the time it began (`at`); one recorded
        # before that field existed counts only when it carries a boot time and its day is the
        # window's first or later. An entry with neither is too old to price.
        #
        # @param row [Hash] one usage entry
        # @param cutoff [Time] the start of the window
        # @return [Boolean]
        def recent?(row, cutoff)
          began = stamp(row)
          return began >= cutoff if began

          row["boot_ms"].is_a?(Numeric) && row["date"].to_s >= cutoff.utc.strftime("%Y-%m-%d")
        end

        # @param row [Hash] one usage entry
        # @return [Time, nil] when the run began, nil when the entry says none
        def stamp(row)
          Time.parse(row["at"].to_s) if row["at"]
        rescue ArgumentError
          nil
        end

        def parse(line)
          row = JSON.parse(line.force_encoding(Encoding::UTF_8))
          row if row.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        def each_line_backwards(path, &)
          File.open(path, "rb") { |file| read_backwards(file, &) }
        end

        def read_backwards(file, &)
          position = file.size
          floor = [position - LIMIT, 0].max
          carry = +""
          while position > floor
            step = [CHUNK, position - floor].min
            position -= step
            carry = take(file, position, step, carry, &)
          end
          yield carry if position.zero? && !carry.empty?
        end

        # The complete lines of one chunk, last first; the partial one at its start is carried to
        # the chunk before it.
        def take(file, position, step, carry, &)
          file.seek(position)
          lines = (file.read(step) + carry).split("\n", -1)
          rest = lines.shift
          lines.reverse_each(&)
          rest
        end
      end
    end
  end
end
