# frozen_string_literal: true

require "json"
require "time"
require "tmpdir"

module Hecks
  module Adapters
    class CiSeeing
      # What keeps a look from asking GitHub on every beat. Each beat is a process of its own, so
      # the last listing is kept in one small file in the temporary directory, and a look within
      # the pace of it is answered that listing again: what it holds is already recorded, so the
      # look finds nothing new and starts no program.
      class Pace
        # Seconds one listing stands before GitHub is asked again.
        EVERY = 120
        # Where the last listing is kept between processes.
        PATH = File.join(Dir.tmpdir, "hecks-ci-look.json")

        # @param path [String] the file the last listing is kept in
        # @param every [Numeric] seconds one listing stands
        # @param now [#call] answers the current time
        def initialize(path: PATH, every: EVERY, now: -> { Time.now })
          @path = path
          @every = every
          @now = now
        end

        # @yieldreturn [Array<Hash>] the listing, read from GitHub
        # @return [Array<Hash>] the last listing while it stands, else a new one, which is kept
        def listing
          kept = last
          return rows_of(kept) if kept["at"] && @now.call - Time.parse(kept["at"]) < @every

          yield.tap { |rows| keep(rows) }
        end

        private

        def rows_of(kept) = Array(kept["rows"]).map { |row| row.transform_keys(&:to_sym) }

        def last
          held = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
          held.is_a?(Hash) ? held : {}
        rescue JSON::ParserError, SystemCallError, ArgumentError
          {}
        end

        def keep(rows)
          File.write(@path, JSON.generate("at" => @now.call.utc.iso8601, "rows" => rows))
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
