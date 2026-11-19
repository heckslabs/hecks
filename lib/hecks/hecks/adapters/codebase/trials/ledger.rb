# frozen_string_literal: true

require "json"
require "fileutils"
require "hecks/cache_dir"

module Hecks
  module Adapters
    module Codebase
      class Trials
        # The machine's trial log: one JSON line for each subject of each run, appended and never
        # edited. Every worktree of the machine appends to the one file, each run in a single
        # write, so the history of a spec or a check accumulates across sessions. It is
        # machine-local, lives under the Hecks cache directory, and a spec reads one only under a
        # temporary directory.
        #
        # A read takes only the file's last `READ_BYTES`, so a long history costs no more to read
        # than a short one.
        class Ledger
          # The log's file name inside the cache directory.
          FILE = "trials.jsonl"

          # How much of the end of the log a read takes.
          READ_BYTES = 1_048_576

          # @param base [#[]] the environment
          # @return [String] the log's path, under `HECKS_CACHE_DIR` when named
          def self.path(base = ENV)
            named = base["HECKS_CACHE_DIR"].to_s
            named.empty? ? Hecks::CacheDir.path(FILE) : File.join(named, FILE)
          end

          # @return [String] the log's path
          attr_reader :path

          # @param path [String] the log's path
          def initialize(path = self.class.path)
            @path = path
          end

          # @param rows [Array<Hash>] one run's rows, appended in one write
          # @return [void]
          # @raise [SystemCallError] when the log cannot be written
          def append(rows)
            FileUtils.mkdir_p(File.dirname(@path))
            text = rows.map { |row| "#{JSON.generate(row)}\n" }.join
            File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.write(text) }
          end

          # @param kind [String] the kind of run, such as `spec` or `gate-quick`
          # @return [Array<Hash>] the rows of that kind in the log's tail, oldest first
          def read(kind)
            return [] unless File.file?(@path)

            tail.filter_map { |line| row(line) }.select { |row| row["kind"] == kind }
          end

          private

          # The log's last lines, without a first line the byte limit cut.
          def tail
            File.open(@path) do |file|
              start = [file.size - READ_BYTES, 0].max
              file.seek(start)
              lines = file.read.lines
              start.positive? ? lines.drop(1) : lines
            end
          end

          def row(line)
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end
      end
    end
  end
end
