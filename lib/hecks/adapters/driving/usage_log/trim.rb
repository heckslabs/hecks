require "fileutils"
require "json"
require "zlib"

module Hecks
  module Adapters
    module Driving
      module UsageLog
        # Keeps the usage record from growing without end: once it is large, the runs older than
        # the window `hecks usage` counts move to a gzipped file for their month, and the runs
        # inside the window stay in the record. The record is rewritten in place under a lock that
        # every append also takes, so a run recorded meanwhile lands after the rewrite.
        module Trim
          # The size above which the record is looked at, in bytes.
          ROTATE_BYTES = 16 * 1024 * 1024

          # How much the record must grow after one look before the next one, so a record made of
          # runs all inside the window is not read through again for nothing.
          GROWTH = 1.25

          # The file that holds the size the record had after the last look.
          MARKER = "usage.trimmed".freeze

          # A `YYYY-MM-DD` date, which compares as text.
          DATE = /\A\d{4}-\d{2}-\d{2}\z/

          module_function

          # @param path [String] the record
          # @return [Boolean] whether the record is large and has grown since the last look
          def due?(path)
            size = File.size(path)
            size > ROTATE_BYTES && size > (last_size(path) * GROWTH)
          rescue SystemCallError
            false
          end

          # Moves the runs older than the window to their month's archive and keeps the rest.
          #
          # @param path [String] the record
          # @param window [Integer] how many days of runs stay
          # @param now [Time] the time the window is counted back from
          # @return [Integer] how many runs moved to an archive
          def run(path, window:, now: Time.now.utc)
            moved = 0
            File.open(path, "r+") do |io|
              io.flock(File::LOCK_EX)
              moved = split(io, (now - (window * 86_400)).strftime("%Y-%m-%d"), File.dirname(path))
            end
            File.write(marker(path), File.size(path).to_s)
            moved
          end

          def split(io, cutoff, dir)
            old, kept = io.each_line.to_a.partition { |line| older?(line, cutoff) }
            return 0 if old.empty?

            archive(old, dir)
            io.truncate(0)
            io.rewind
            io.write(kept.join)
            io.flush
            old.size
          end

          def older?(line, cutoff)
            row = JSON.parse(line)
            row.is_a?(Hash) && row["date"].to_s.match?(DATE) && row["date"] < cutoff
          rescue JSON::ParserError
            false
          end

          # Appends each month's runs to its gzip file. Gzip members concatenate, so an archive that
          # already exists is added to, not replaced.
          def archive(lines, dir)
            lines.group_by { |line| month(line) }.each do |name, rows|
              File.open(File.join(dir, "usage-#{name}.jsonl.gz"), "ab") do |io|
                gz = Zlib::GzipWriter.new(io)
                gz.write(rows.join)
                gz.finish
              end
            end
          end

          def month(line) = JSON.parse(line)["date"].to_s[0, 7].delete("-")

          def marker(path) = File.join(File.dirname(path), MARKER)

          def last_size(path) = File.exist?(marker(path)) ? File.read(marker(path)).to_i : 0
        end
      end
    end
  end
end
