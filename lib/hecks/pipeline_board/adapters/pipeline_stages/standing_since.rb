# frozen_string_literal: true

require "json"
require "tmpdir"

module Hecks
  module Adapters
    module PipelineBoard
      # When each stage and each metric last changed its state, so the board can say how long one
      # has needed attention. A reading says only what state a row is in now; this remembers the
      # state it was in at the last reading and the time it moved. The board restarts whenever its
      # code moves, so what it remembers is kept in one small file in the temporary directory.
      class StandingSince
        # Where a serving board keeps the times between restarts.
        PATH = File.join(Dir.tmpdir, "hecks-pipeline-board-since.json")
        # The field that names a row of each kind.
        NAMED_BY = { "stage" => :name, "metric" => :id }.freeze
        # The sections of the board's state whose rows are stamped, each with its rows' kind.
        KINDS = { stages: "stage", metrics: "metric" }.freeze

        class << self
          # The memory a serving board keeps; nil until one stands, so a reading taken by anything
          # else (a command, a spec) writes no file.
          # @return [StandingSince, nil]
          attr_accessor :shared

          # Starts this process's memory, once, from the file the last board left.
          #
          # @return [StandingSince]
          def stand = self.shared ||= new(path: PATH)

          # @param kind [String] `stage` or `metric`
          # @param rows [Array<Hash>] the rows of a reading
          # @param now [Time] the time of the reading
          # @return [Array<Hash>] the rows, each with the `since` its state has stood from; the rows
          #   as they are when no board stands
          def stamp(kind, rows, now) = shared ? shared.stamp(kind, rows, now) : rows

          # @param state [Hash] the board's state, with its `stages` and `metrics`
          # @param now [Time] the time of the reading
          # @return [Hash] the state with each stage and each metric stamped; a section that was
          #   not read (it holds no rows) is left as it is
          def over(state, now = Time.now)
            read = KINDS.select { |section, _| state[section].is_a?(Array) }
            state.merge(read.to_h { |section, kind| [section, stamp(kind, state[section], now)] })
          end
        end

        # @param path [String, nil] the file the times are kept in; none keeps them in memory only
        def initialize(path: nil)
          @path = path
          @lock = Mutex.new
          @held = kept_before
        end

        # @param kind [String] what the rows are, which keeps a stage and a metric of one name apart
        # @param rows [Array<Hash>, Object] a reading's rows; anything else is answered as it is
        # @param now [Time] the time of the reading
        # @return [Array<Hash>] the rows, each with the `since` its state has stood from
        def stamp(kind, rows, now)
          return rows unless rows.is_a?(Array)

          @lock.synchronize do
            before = @held.dup
            stamped = rows.map { |row| row.merge(since: since(kind, row, now)) }
            keep unless @held == before
            stamped
          end
        end

        private

        # The time the row's state has stood from: the one remembered when the state is the same,
        # else now, which is remembered in its place.
        def since(kind, row, now)
          key = "#{kind}:#{row[NAMED_BY.fetch(kind)]}"
          state, at = @held[key]
          return at if state == row[:state].to_s

          (@held[key] = [row[:state].to_s, now.utc.iso8601]).last
        end

        def kept_before
          held = @path && File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
          held.is_a?(Hash) ? held : {}
        rescue JSON::ParserError, SystemCallError
          {}
        end

        def keep
          File.write(@path, JSON.generate(@held)) if @path
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
